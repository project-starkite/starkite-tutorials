#!/usr/bin/env kite --allow-all
# 10-crd-operator.star - Custom Resource Definition (CRD) + Operator Pattern
#
# Demonstrates:
#   - k8s.obj.crd(): Programmatic definition of CustomResourceDefinitions in Starlark
#   - Functional desired-state child return: reconcile() returns [child_dep, child_svc]
#   - Automatic OwnerReference injection linking child workloads to parent CR
#   - Server-Side Apply (SSA) and automatic child informer auto-watching
#   - Automatic orphan resource pruning when child definitions are removed
#   - Automatic Ready condition updates and Kubernetes event emission
#   - Declarative teardown hook via finalize() and Kubernetes finalizers
#   - Embedded health and readiness HTTP endpoints (/healthz, /readyz)
#
# Usage:
#   # Step 1: Install CRD and start the operator (Terminal 1):
#   kite run ./10-crd-operator.star --allow-all
#
#   # Step 2: Apply a sample StaticSite custom resource (Terminal 2):
#   kite run ./10-crd-operator.star --var action=sample --allow-all
#
#   # Step 3: Verify child resources and status conditions:
#   kubectl get staticsites,deployments,services -l managed-by=staticsite-operator
#   kubectl describe staticsite tutorial-site
#   curl -i http://localhost:8081/healthz
#
#   # Step 4: Verify child drift auto-correction (tamper with child deployment):
#   kubectl scale deployment tutorial-site --replicas=10
#   # Notice: Child watch detects the change and restores replicas to declared count (2)
#
#   # Step 5: Clean up sample instance and operator:
#   kite run ./10-crd-operator.star --var action=cleanup-sample --allow-all
#   kite run ./10-crd-operator.star --var action=uninstall-crd --allow-all

def build_crd():
    """Constructs the OpenAPI v3 schema for the StaticSite custom resource."""
    return k8s.obj.crd(
        group = "tutorial.starkite.io",
        version = "v1alpha1",
        kind = "StaticSite",
        plural = "staticsites",
        scope = "Namespaced",
        spec = {
            "image": {"type": "string", "default": "nginx:1.27-alpine"},
            "replicas": {"type": "integer", "default": 1},
            "port": {"type": "integer", "default": 80},
            "title": {"type": "string", "default": "Starkite Operator Site"},
        },
        status = {
            "ready": {"type": "boolean"},
            "deployment": {"type": "string"},
            "conditions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "type": {"type": "string"},
                        "status": {"type": "string"},
                        "lastTransitionTime": {"type": "string"},
                        "reason": {"type": "string"},
                        "message": {"type": "string"},
                        "observedGeneration": {"type": "integer"},
                    },
                },
            },
        },
    )

def reconcile(site):
    """Reconciles the desired state of a StaticSite custom resource.

    Returns a list of desired child resources. The controller substrate:
    1. Injects OwnerReferences pointing to the parent StaticSite CR
    2. Spawns child informers (auto-watch) so child drift triggers re-reconciliation
    3. Applies resources via Server-Side Apply (fieldManager: starkite)
    4. Automatically prunes orphaned child resources
    5. Updates status.conditions with Type=Ready, Status=True, Reason=Reconciled
    6. Emits a Normal Reconciled Kubernetes event
    """
    name = site.metadata.name
    res_ns = site.metadata.namespace
    spec = site.spec
    image = spec.get("image", "nginx:1.27-alpine")
    replicas = spec.get("replicas", 1)
    port = spec.get("port", 80)
    title = spec.get("title", "Starkite Operator Site")

    print("[RECONCILE] StaticSite %s/%s (image=%s, replicas=%d, port=%d)" % (
        res_ns, name, image, replicas, port
    ))

    # Child Deployment
    child_dep = k8s.obj.deployment(
        name = name,
        namespace = res_ns,
        replicas = replicas,
        labels = {
            "app": name,
            "managed-by": "staticsite-operator",
        },
        containers = [
            k8s.obj.container(
                name = "web",
                image = image,
                ports = [k8s.obj.container_port(container_port=port, name="http")],
            )
        ],
    )

    # Child Service
    child_svc = k8s.obj.service(
        name = name,
        namespace = res_ns,
        labels = {
            "app": name,
            "managed-by": "staticsite-operator",
        },
        selector = {
            "app": name,
        },
        ports = [
            k8s.obj.service_port(port=port, target_port=port, name="http"),
        ],
    )

    return [child_dep, child_svc]

def finalize(site):
    """Declarative teardown hook executed before the custom resource is deleted.

    Called by the controller runtime when deletionTimestamp is set. Once finalize()
    completes cleanly, the runtime automatically removes the finalizer to allow
    standard Kubernetes cascading deletion to proceed.
    """
    name = site.metadata.name
    res_ns = site.metadata.namespace
    print("[FINALIZE] Executing teardown hook for StaticSite %s/%s..." % (res_ns, name))
    return None

def main():
    action = var_str("action", "run").lower()
    ns = var_str("namespace", "default")
    health_port = var_int("health_port", 8081)
    crd_name = "staticsites.tutorial.starkite.io"

    # Action: sample (creates a sample CR instance)
    if action == "sample":
        print("=== Creating Sample StaticSite Resource ===")
        sample_site = {
            "apiVersion": "tutorial.starkite.io/v1alpha1",
            "kind": "StaticSite",
            "metadata": {
                "name": "tutorial-site",
                "namespace": ns,
                "labels": {
                    "app": "tutorial-site",
                    "managed-by": "staticsite-operator",
                },
            },
            "spec": {
                "image": "nginx:1.27-alpine",
                "replicas": 2,
                "port": 80,
                "title": "Welcome to Starkite Operator Tutorial",
            },
        }
        k8s.apply(sample_site)
        print("Applied StaticSite custom resource: %s/%s" % (ns, "tutorial-site"))
        return

    # Action: cleanup-sample
    if action == "cleanup-sample":
        print("=== Deleting Sample StaticSite Resource ===")
        k8s.delete("staticsite", "tutorial-site", namespace=ns)
        print("Deleted StaticSite tutorial-site.")
        return

    # Action: uninstall-crd
    if action == "uninstall-crd":
        print("=== Uninstalling StaticSite CRD ===")
        k8s.delete("customresourcedefinition", crd_name)
        print("Uninstalled %s." % crd_name)
        return

    # Action: run (Default)
    print("=== 1. Ensuring StaticSite CRD is Installed ===")
    crd = build_crd()
    k8s.apply(crd)
    k8s.wait_for("customresourcedefinition", crd_name, condition="Established", timeout="30s")
    print("CRD %s is Established and ready.\n" % crd_name)

    print("=== 2. Starting StaticSite Operator ===")
    print("Watching for StaticSite events in namespace: %s" % ns)
    print("Health Probes : http://localhost:%d/healthz and /readyz" % health_port)
    print("Press Ctrl+C to stop the operator.\n")

    # Start controller with functional child reconciliation, finalizer, and health probes
    k8s.control(
        "staticsites",
        reconcile = reconcile,
        finalize = finalize,
        finalizer = "tutorial.starkite.io/finalizer",
        namespace = ns,
        health_port = health_port,
        workers = 2,
    )
