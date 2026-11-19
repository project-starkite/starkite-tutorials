#!/usr/bin/env kite
"""Edge container reconciliation agent.

Watches ContainerApp resources labeled for a specific edge site in a central
Kubernetes cluster and reconciles them against the local Podman/Docker daemon.
"""

FINALIZER = "edge.starkite.io/container"
SITE_LABEL = "edge.starkite.io/site"
DEFAULT_SITE = "site-a"
DEFAULT_NAMESPACE = "edge-fleet"
DEFAULT_POLL = "15s"
DEFAULT_HEALTH_PORT = 18081

def parse_cli():
    args.string("site", shorthand = "s", default = DEFAULT_SITE, help = "Edge site identifier matching label edge.starkite.io/site")
    args.string("namespace", shorthand = "n", default = DEFAULT_NAMESPACE, help = "Kubernetes namespace to watch")
    args.string("poll", default = DEFAULT_POLL, help = "Periodic drift-detection reconciliation interval")
    args.int("health-port", default = DEFAULT_HEALTH_PORT, min = 1, max = 65535, help = "Local HTTP port for /healthz and /readyz probes")
    return args.parse()

def site_selector(site):
    """Build the Kubernetes label selector for this edge site."""
    return "%s=%s" % (SITE_LABEL, site)

def site_from_object(app):
    """Extract the target site from ContainerApp metadata labels."""
    labels = app.get("metadata", {}).get("labels", {})
    return labels.get(SITE_LABEL, DEFAULT_SITE)

def container_name(site, app_name):
    """Return the deterministic local container name for a ContainerApp on a site."""
    return "edge-%s-%s" % (site, app_name)

def to_plain_dict(mapping):
    """Convert an AttrDict or dict to a plain Starlark dict required by containers.run."""
    if not mapping:
        return {}
    return {k: mapping[k] for k in mapping.keys()}

def format_host_ports(ports_spec):
    """Format port bindings for kubectl printer column output (e.g. '18080->80/tcp')."""
    if not ports_spec:
        return "-"
    parts = []
    for container_port in sorted(ports_spec.keys()):
        parts.append("%s->%s" % (ports_spec[container_port], container_port))
    return ",".join(parts)

def extract_spec(app):
    """Extract normalized container fields from a ContainerApp object."""
    spec = app.get("spec", {})
    raw_cmd = spec.get("command", None)
    cmd = list(raw_cmd) if raw_cmd else []
    return {
        "image": spec.get("image", ""),
        "command": cmd,
        "ports": to_plain_dict(spec.get("ports", None)),
        "env": to_plain_dict(spec.get("env", None)),
    }

def build_status(box, site, desired_image, ports_spec, generation):
    """Build the ContainerApp status subresource payload from a container snapshot."""
    cid = box["id"][:12] if box and box.get("id") else ""
    running = box != None and box.get("status") == "running"
    phase = "Running" if running else "Degraded"
    cname = box["name"] if box else ""
    msg = (
        "Container %s running on %s" % (cname, site)
        if running
        else "Container %s is %s on %s" % (cname, box.get("status", "missing") if box else "missing", site)
    )
    return {
        "site": site,
        "phase": phase,
        "containerId": cid,
        "image": desired_image,
        "hostPort": format_host_ports(ports_spec),
        "message": msg,
        "observedGeneration": generation,
        "conditions": [
            {
                "type": "Ready",
                "status": "True" if running else "False",
                "reason": "ContainerRunning" if running else "ContainerNotRunning",
                "message": msg,
                "observedGeneration": generation,
            },
        ],
    }

def status_matches(current, desired):
    """Return True when key status fields already match to avoid redundant API writes."""
    if not current:
        return False
    for key in ["site", "phase", "containerId", "image", "hostPort", "observedGeneration"]:
        if current.get(key) != desired.get(key):
            return False
    return True

def find_container(cname):
    """Find a container by exact name via list(all=True), returning None if absent."""
    res = containers.try_list(all = True)
    if not res.ok:
        log.warn("Failed to list containers", attrs = {"error": str(res.err)})
        return None
    for box in res.value:
        if box["name"].lstrip("/") == cname:
            return box
    return None

def ensure_container(cname, spec):
    """Ensure the named container is running with the desired image; return (box, changed)."""
    existing = find_container(cname)
    if existing != None:
        if existing["status"] == "running" and existing["image"] == spec["image"]:
            return existing, False
        log.info("Replacing drifted or outdated container", attrs = {
            "container": cname,
            "current_status": existing["status"],
            "current_image": existing["image"],
            "desired_image": spec["image"],
        })
        rm_res = containers.try_remove(cname, force = True)
        if not rm_res.ok:
            log.warn("Failed to remove existing container before recreate", attrs = {"container": cname, "error": str(rm_res.err)})

    log.info("Pulling container image", attrs = {"image": spec["image"], "container": cname})
    containers.image_pull(spec["image"])

    run_kwargs = {
        "name": cname,
        "detach": True,
    }
    if spec["command"]:
        run_kwargs["command"] = spec["command"]
    if spec["ports"]:
        run_kwargs["ports"] = spec["ports"]
    if spec["env"]:
        run_kwargs["env"] = spec["env"]

    box = containers.run(spec["image"], **run_kwargs)
    return box, True

def reconcile(app):
    """Reconcile a ContainerApp resource against the local container daemon."""
    name = app.metadata.name
    namespace = app.metadata.namespace
    site = site_from_object(app)
    generation = app.metadata.get("generation", 1)
    spec = extract_spec(app)
    cname = container_name(site, name)

    box, changed = ensure_container(cname, spec)
    desired_status = build_status(box, site, spec["image"], spec["ports"], generation)
    current_status = app.get("status", {})

    if not status_matches(current_status, desired_status):
        k8s.status(app, desired_status, namespace = namespace)

    if changed:
        ev_res = k8s.try_event(
            app,
            "Reconciled",
            "Container %s running image %s on %s" % (cname, spec["image"], site),
            namespace = namespace,
        )
        if not ev_res.ok:
            log.warn("Failed to emit Reconciled event", attrs = {"app": name, "error": str(ev_res.err)})
        log.info("Reconciled ContainerApp", attrs = {
            "app": name,
            "site": site,
            "container": cname,
            "image": spec["image"],
            "container_id": desired_status["containerId"],
        })

def finalize(app):
    """Remove the local container before Kubernetes deletes the ContainerApp."""
    name = app.metadata.name
    site = site_from_object(app)
    cname = container_name(site, name)
    if find_container(cname) != None:
        rm_res = containers.try_remove(cname, force = True)
        if rm_res.ok:
            log.info("Removed container during finalization", attrs = {
                "app": name,
                "site": site,
                "container": cname,
            })
        else:
            log.warn("Failed to remove container during finalization", attrs = {
                "app": name,
                "site": site,
                "container": cname,
                "error": str(rm_res.err),
            })

def on_delete(app):
    """Log completion once a ContainerApp has been finalized and removed."""
    log.info("ContainerApp deleted", attrs = {
        "app": app.metadata.name,
        "namespace": app.metadata.namespace,
    })

def main():
    cli = parse_cli()
    selector = site_selector(cli.site)

    log.info("Starting edge container agent", attrs = {
        "site": cli.site,
        "namespace": cli.namespace,
        "selector": selector,
        "poll": cli.poll,
        "health_port": cli.health_port,
    })

    k8s.control(
        "containerapps",
        reconcile = reconcile,
        finalize = finalize,
        on_delete = on_delete,
        finalizer = FINALIZER,
        namespace = cli.namespace,
        labels = selector,
        poll = cli.poll,
        health_port = cli.health_port,
    )
