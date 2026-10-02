#!/usr/bin/env kite --allow-all
# 07-controller.star - Custom Kubernetes controller with active reconciliation
#
# Demonstrates:
#   - k8s.control(): Substrate-driven controller runtime with active reconciliation loop
#   - Single reconcile(obj) handler replacing fragmented event hooks
#   - Inherent generation filtering & self-echo suppression (loop immunity)
#   - Automated drift correction: Detecting replica tampering and restoring declared state
#   - Automatic lifecycle event emission and domain event reporting via k8s.event()
#   - Embedded health & readiness HTTP server (/healthz, /readyz)
#   - Periodic reconciliation via poll parameter
#
# Usage:
#   # Terminal 1: Run the controller
#   kite run ./07-controller.star --allow-all
#
#   # Terminal 2: Test drift correction
#   kubectl create deployment drift-demo --image=nginx:alpine
#   kubectl label deployment drift-demo app=drift-monitor --overwrite
#   kubectl scale deployment drift-demo --replicas=8
#   # Observe the controller instantly detecting drift and scaling it back down to max_replicas (3)
#   kubectl get events --field-selector involvedObject.name=drift-demo
#   curl -i http://localhost:8081/healthz
#   kubectl delete deployment drift-demo

load("k8s", "k8s")

def reconcile(deploy):
    """Reconciles deployment state, enforcing the maximum replica limit policy."""
    max_replicas = var_int("max_replicas", 3)
    name = deploy.metadata.name
    ns = deploy.metadata.namespace
    replicas = deploy.spec.get("replicas", 1)

    print("[RECONCILE] Inspecting deployment %s/%s (replicas: %d, max: %d)" % (
        ns, name, replicas, max_replicas
    ))

    if replicas > max_replicas:
        print("[DRIFT DETECTED] %s/%s has %d replicas (exceeds policy max %d)" % (
            ns, name, replicas, max_replicas
        ))
        print("[REMEDIATING] Scaling %s/%s back to %d replicas..." % (ns, name, max_replicas))

        # Correct drift using server-side merge patch.
        # Note: The substrate's self-echo suppression prevents this patch
        # from creating an infinite reconciliation loop.
        k8s.patch("deployment", name, {
            "spec": {"replicas": max_replicas}
        }, namespace=ns)

        # Emit custom Kubernetes event attached to the deployment
        k8s.event(
            deploy,
            reason = "DriftCorrected",
            message = "Scaled down replicas from %d to %d" % (replicas, max_replicas),
            type = "Normal",
            namespace = ns,
        )
        print("[REMEDIATED] %s/%s restored to %d replicas" % (ns, name, max_replicas))
    else:
        print("[IN POLICY] %s/%s replica count %d is within limits (<= %d)" % (
            ns, name, replicas, max_replicas
        ))

    return None

def main():
    target_ns = var_str("namespace", "default")
    max_replicas = var_int("max_replicas", 3)
    selector = var_str("selector", "app=drift-monitor")
    health_port = var_int("health_port", 8081)

    print("=== Workload Drift-Monitor Controller ===")
    print("Namespace     : %s" % target_ns)
    print("Label Selector: %s" % selector)
    print("Max Replicas  : %d" % max_replicas)
    print("Health Probes : http://localhost:%d/healthz and /readyz" % health_port)
    print("Starting reconcile loop (press Ctrl+C to stop)...\n")

    # Start controller with active reconcile loop, health port, and resync polling
    k8s.control(
        "deployments",
        reconcile = reconcile,
        namespace = target_ns,
        labels = selector,
        poll = "30s",
        health_port = health_port,
        workers = 2,
    )

