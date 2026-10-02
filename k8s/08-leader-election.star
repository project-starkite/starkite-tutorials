#!/usr/bin/env kite --allow-all
# 08-leader-election.star - High-availability controller with distributed lease election
#
# Demonstrates:
#   - Distributed coordination using Kubernetes coordination.k8s.io/v1 Lease resources
#   - Active reconciliation handler reconcile(obj) executed only by the elected leader
#   - leader_election=True in k8s.control()
#   - Embedded HTTP health and readiness probes (/healthz, /readyz)
#   - Dynamic readiness probe status: 200 OK on leader, 503 Service Unavailable on standby
#   - Standby replicas maintaining passive watches while leader processes workqueue items
#   - Automatic leader failover upon process termination
#   - Querying active Lease metadata (holder identity, duration, renewal timestamp)
#
# Usage:
#   # Terminal 1: Run Replica 1 (Becomes Leader, health_port=8081)
#   kite run ./08-leader-election.star --var id=replica-1 --var health_port=8081 --allow-all
#
#   # Terminal 2: Run Replica 2 (Becomes Standby, health_port=8082)
#   kite run ./08-leader-election.star --var id=replica-2 --var health_port=8082 --allow-all
#
#   # Terminal 3: Verify readiness endpoints
#   curl -i http://localhost:8081/readyz   # HTTP 200 OK (Leader active)
#   curl -i http://localhost:8082/readyz   # HTTP 503 Service Unavailable (Standby)
#
#   # Inspect the active cluster Lease:
#   kite run ./08-leader-election.star --var inspect=true --allow-all
#
#   # Test reconciliation event handling:
#   kubectl create configmap leader-demo-cm --from-literal=role=primary
#   kubectl label configmap leader-demo-cm app=leader-demo
#   # Notice: Only the active leader processes the reconciliation event.
#
#   # Test failover: Terminate Replica 1 (Ctrl+C in Terminal 1).
#   # Within ~15s, Replica 2 acquires the lease and starts leading:
#   curl -i http://localhost:8082/readyz   # Transitions to HTTP 200 OK!
#
#   # Clean up:
#   kubectl delete configmap leader-demo-cm

def reconcile(cm):
    """Reconciles the ConfigMap. Executed only by the active leader replica."""
    replica_id = var_str("id", "replica-1")
    data = cm.data if cm.data != None else {}
    print("[%s - LEADER] Reconciled ConfigMap: %s/%s (keys: %d)" % (
        replica_id,
        cm.metadata.namespace,
        cm.metadata.name,
        len(data),
    ))
    return None

def main():
    lease_name = var_str("lease_name", "tutorial-controller-leader")
    lease_ns = var_str("namespace", "default")
    is_inspect = var_bool("inspect", False)
    client = k8s.config(namespace=lease_ns)

    # If inspect mode is requested, query and display the Lease object
    if is_inspect:
        print("=== Inspecting Kubernetes Leader Lease ===")
        check = client.try_get("lease", lease_name)
        if not check.ok:
            print("Lease %s/%s does not exist or has not been acquired yet." % (lease_ns, lease_name))
            return

        lease = check.value
        spec = lease.spec
        print("Lease Name         : %s/%s" % (lease.metadata.namespace, lease.metadata.name))
        print("Holder Identity    : %s" % spec.get("holderIdentity", "None"))
        print("Lease Duration (s) : %s" % spec.get("leaseDurationSeconds", "None"))
        print("Acquire Time       : %s" % spec.get("acquireTime", "None"))
        print("Renew Time         : %s" % spec.get("renewTime", "None"))
        print("Lease Transitions  : %s" % spec.get("leaseTransitions", "0"))
        return

    # Normal mode: Start leader-elected controller replica
    replica_id = var_str("id", "replica-1")
    health_port = var_int("health_port", 8081)

    print("=== Starting Leader-Elected Controller Replica ===")
    print("Replica ID        : %s" % replica_id)
    print("Target Lease Name : %s" % lease_name)
    print("Lease Namespace   : %s" % lease_ns)
    print("Health Probes     : http://localhost:%d/healthz and /readyz" % health_port)
    print("Contending for leadership lease (press Ctrl+C to stop)...\n")

    # Start controller with leader election and health probe endpoints enabled
    k8s.control(
        "configmaps",
        reconcile = reconcile,
        namespace = lease_ns,
        labels = "app=leader-demo",
        leader_election = True,
        leader_election_id = lease_name,
        leader_election_namespace = lease_ns,
        identity = replica_id,
        health_port = health_port,
    )

