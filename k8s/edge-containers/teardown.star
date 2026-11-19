#!/usr/bin/env kite
"""Tear down edge-containers workloads, local containers, and hub resources."""

DEFAULT_NAMESPACE = "edge-fleet"
CRD_NAME = "containerapps.edge.starkite.io"

def parse_cli():
    args.string("namespace", shorthand = "n", default = DEFAULT_NAMESPACE, help = "Target namespace to delete")
    args.string("site", shorthand = "s", default = "", help = "Optional site filter for local container cleanup (empty removes all edge-* containers)")
    args.bool("delete-crd", default = False, help = "Also delete the ContainerApp CRD from the hub cluster")
    args.string("kubeconfig", default = "", help = "Path to kubeconfig (defaults to KUBECONFIG / ~/.kube/config)")
    args.string("context", default = "", help = "Optional kubeconfig context name")
    args.string("container-host", default = "", help = "Container daemon socket URI (defaults to auto-discovery)")
    return args.parse()

def is_managed_container(name, site = ""):
    """Return True if a local container name belongs to the edge agent (and optional site)."""
    clean = name.lstrip("/")
    prefix = "edge-%s-" % site if site else "edge-"
    return clean.startswith(prefix)

def cleanup_local_containers(site = "", container_host = ""):
    """Force-remove local containers matching the edge prefix."""
    cfg = containers.try_config(host = container_host) if container_host else containers.try_config()
    if not cfg.ok:
        log.warn("Skipping local container cleanup: daemon unavailable", attrs = {"error": str(cfg.err)})
        return 0

    docker = cfg.value
    listed = docker.try_list(all = True)
    if not listed.ok:
        log.warn("Failed to list local containers", attrs = {"error": str(listed.err)})
        return 0

    removed = 0
    for box in listed.value:
        cname = box["name"]
        if is_managed_container(cname, site):
            res = docker.try_remove(cname, force = True)
            if res.ok:
                removed += 1
                log.info("Removed local container", attrs = {"container": cname})
            else:
                log.warn("Failed to remove local container", attrs = {"container": cname, "error": str(res.err)})
    return removed

def delete_apps(client, namespace):
    """Delete ContainerApp resources and strip stale finalizers if no agent is running."""
    listed = client.try_list("containerapps", namespace = namespace)
    if not listed.ok:
        return 0

    apps = listed.value
    if len(apps) == 0:
        return 0

    for app in apps:
        del_res = client.try_delete("containerapps", app.metadata.name, namespace = namespace)
        if not del_res.ok:
            log.warn("Failed to delete ContainerApp", attrs = {"app": app.metadata.name, "error": str(del_res.err)})

    # Give a running agent a short window to execute its finalizer before forcing removal.
    wait_res = retry.try_do(
        lambda: client.try_list("containerapps", namespace = namespace),
        max_attempts = 6,
        delay = "1s",
        retry_on = lambda r: r.ok and len(r.value) > 0,
    )
    if not wait_res.ok:
        log.info("ContainerApps still pending finalization", attrs = {"namespace": namespace})

    remaining = client.try_list("containerapps", namespace = namespace)
    if remaining.ok and len(remaining.value) > 0:
        for stale in remaining.value:
            sname = stale.metadata.name
            log.warn("Stripping stale finalizer from ContainerApp", attrs = {"app": sname, "namespace": namespace})
            patch_res = client.try_patch(
                "containerapps",
                sname,
                {"metadata": {"finalizers": []}},
                namespace = namespace,
                type = "merge",
            )
            if not patch_res.ok:
                log.warn("Failed to strip finalizer", attrs = {"app": sname, "error": str(patch_res.err)})
    return len(apps)

def down(namespace = DEFAULT_NAMESPACE, site = "", delete_crd = False, kubeconfig = "", context = "", container_host = ""):
    """Remove ContainerApp instances, local edge containers, namespace, and optional CRD."""
    client = k8s.config(kubeconfig = kubeconfig, context = context, namespace = namespace)

    app_count = delete_apps(client, namespace)
    if app_count > 0:
        log.info("Deleted ContainerApp resources", attrs = {"count": app_count, "namespace": namespace})

    removed = cleanup_local_containers(site = site, container_host = container_host)
    if removed > 0:
        log.info("Removed local edge containers", attrs = {"count": removed, "site": site or "*"})

    ns_del = client.try_delete("namespace", namespace)
    if ns_del.ok:
        log.info("Deleting namespace", attrs = {"namespace": namespace})
        ns_wait = retry.try_do(
            lambda: client.try_get("namespace", namespace),
            max_attempts = 30,
            delay = "1s",
            retry_on = lambda r: r.ok,
        )
        if not ns_wait.ok:
            log.warn("Namespace wait interrupted", attrs = {"namespace": namespace, "error": str(ns_wait.err)})
        still_there = client.try_get("namespace", namespace)
        if still_there.ok:
            log.warn("Namespace still terminating after timeout", attrs = {"namespace": namespace})

    if delete_crd:
        crd_del = client.try_delete("customresourcedefinition", CRD_NAME)
        if crd_del.ok:
            log.info("Deleted CRD", attrs = {"crd": CRD_NAME})

    print("Teardown complete (namespace: %s, delete_crd: %s)." % (namespace, delete_crd))

def main():
    cli = parse_cli()
    down(
        namespace = cli.namespace,
        site = cli.site,
        delete_crd = cli.delete_crd,
        kubeconfig = cli.kubeconfig,
        context = cli.context,
        container_host = cli.container_host,
    )
