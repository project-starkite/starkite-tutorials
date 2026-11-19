#!/usr/bin/env kite
"""Bootstrap the hub Kubernetes cluster for the edge-containers tutorial.

Applies namespace.yaml, rbac-agent.yaml, and crd-containerapp.yaml, then waits
for the ContainerApp CRD to reach the Established condition.
"""

DEFAULT_NAMESPACE = "edge-fleet"
CRD_NAME = "containerapps.edge.starkite.io"
MANIFEST_FILES = [
    "namespace.yaml",
    "rbac-agent.yaml",
    "crd-containerapp.yaml",
]

def parse_cli():
    args.string("namespace", shorthand = "n", default = DEFAULT_NAMESPACE, help = "Target namespace for edge workloads and RBAC")
    args.string("kubeconfig", default = "", help = "Path to kubeconfig (defaults to KUBECONFIG / ~/.kube/config)")
    args.string("context", default = "", help = "Optional kubeconfig context name")
    return args.parse()

def retarget_manifest(doc, namespace):
    """Rewrite namespace-scoped metadata when a non-default namespace is selected."""
    kind = doc.get("kind", "")
    metadata = doc.get("metadata", {})
    if kind == "Namespace":
        metadata["name"] = namespace
    elif kind in ["ServiceAccount", "Role", "RoleBinding"]:
        metadata["namespace"] = namespace
        if kind == "RoleBinding":
            for subject in doc.get("subjects", []):
                subject["namespace"] = namespace
    return doc

def apply_manifest_file(client, filename, namespace):
    """Decode all YAML documents in filename and apply each to the hub cluster."""
    docs = yaml.file(filename).decode_all()
    applied = []
    for doc in docs:
        if doc == None:
            continue
        retargeted = retarget_manifest(doc, namespace)
        client.apply(retargeted)
        kind = retargeted.get("kind", "Resource")
        name = retargeted.get("metadata", {}).get("name", "")
        applied.append("%s/%s" % (kind, name))
    return applied

def up(namespace = DEFAULT_NAMESPACE, kubeconfig = "", context = ""):
    """Install the namespace, least-privilege RBAC, and ContainerApp CRD."""
    client = k8s.config(kubeconfig = kubeconfig, context = context, namespace = namespace)
    ver = client.version()
    ctx = client.context()
    log.info("Connected to hub Kubernetes cluster", attrs = {
        "context": ctx,
        "server_version": ver.git_version,
        "namespace": namespace,
    })

    for filename in MANIFEST_FILES:
        resources = apply_manifest_file(client, filename, namespace)
        log.info("Applied manifest", attrs = {"file": filename, "resources": resources})

    crd_wait = client.wait_for(
        "customresourcedefinition",
        CRD_NAME,
        condition = "Established",
        timeout = "30s",
    )
    if not crd_wait.ready:
        fail("CRD %s did not become Established: %s" % (CRD_NAME, crd_wait.message))

    log.info("Hub cluster ready", attrs = {"crd": CRD_NAME, "namespace": namespace})
    print("")
    print("Hub cluster configured (context: %s, namespace: %s)." % (ctx, namespace))
    print("")
    print("Next steps:")
    print("  1. Start the edge agent (Terminal 1):")
    print("     kite run ./edge_agent.star --site=site-a --namespace=%s --timeout=0 --allow-all" % namespace)
    print("  2. Deploy a sample ContainerApp (Terminal 2):")
    print("     kubectl apply -f app-web.yaml")
    print("     kubectl get capp -n %s" % namespace)

def main():
    cli = parse_cli()
    up(namespace = cli.namespace, kubeconfig = cli.kubeconfig, context = cli.context)
