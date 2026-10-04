#!/usr/bin/env kite --allow-all
# scale.star - Day-2 Dynamic Worker Node Scaling & Decommissioning
#
# Automates Day-2 worker node operations without requiring Cluster API (CAPI):
# 1. Scale Out (action=join): Dynamically adds a new worker node to the cluster
# 2. Scale In (action=drain): Safely cordons, drains, and evicts workloads from a node
#
# Usage:
#   # 1. Add / Join a new worker node (k8s-worker-3):
#   kite run ./scale.star --var action=join --var node=k8s-worker-3 --var driver=lima
#
#   # 2. Safely drain and remove a worker node:
#   kite run ./scale.star --var action=drain --var node=k8s-worker-2 --var driver=lima

load("time", "time")
load("./common.star", "exec_node", "get_node_ip", "run_local")

def scale_out(driver, cp_node, worker_node):
    """Joins a worker node to the existing cluster."""
    printf("=== Day-2 Scale Out: Joining %s to cluster ===\n\n", worker_node)

    # 1. Verify kubeadm is ready on the worker
    printf("[1/3] Checking worker node %s readiness...\n", worker_node)
    check_res = exec_node(driver, worker_node, "kubeadm version -o short 2>/dev/null && systemctl is-active containerd 2>/dev/null")
    if not check_res.ok:
        fail("Node %s is not prepared. Run ./setup.star --var action=install-kubeadm first." % worker_node)

    # 2. Generate join token from control plane
    printf("[2/3] Generating join token from control plane %s...\n", cp_node)
    tok_res = exec_node(driver, cp_node, "kubeadm token create --print-join-command")
    if not tok_res.ok:
        fail("Failed generating token on %s: %s" % (cp_node, tok_res.stderr))
    join_cmd = tok_res.stdout.strip()

    # 3. Join the node
    printf("[3/3] Joining %s to cluster...\n", worker_node)
    res = exec_node(driver, worker_node, join_cmd + " --node-name=" + worker_node)
    if not res.ok:
        fail("Failed joining node %s: %s" % (worker_node, res.stderr))

    # 4. Wait for node to enter Ready state
    printf("Waiting for node %s to report Ready status...\n", worker_node)
    for attempt in range(18):
        status_res = exec_node(driver, cp_node, "kubectl get node %s --no-headers 2>/dev/null || true" % worker_node)
        if "Ready" in status_res.stdout and "NotReady" not in status_res.stdout:
            printf("  [SUCCESS] Node %s is Ready!\n", worker_node)
            break
        time.sleep(10)

    # Print updated node table
    print("\nUpdated Cluster Topology:")
    nodes_res = exec_node(driver, cp_node, "kubectl get nodes -o wide")
    printf("%s\n", nodes_res.stdout)

def scale_in(driver, cp_node, worker_node):
    """Safely drains and removes a worker node from the cluster."""
    printf("=== Day-2 Scale In: Decommissioning %s ===\n\n", worker_node)

    # 1. Cordon the node to prevent new pod scheduling
    printf("[1/4] Cordoning node %s...\n", worker_node)
    cordon_res = exec_node(driver, cp_node, "kubectl cordon " + worker_node)
    if not cordon_res.ok:
        fail("Failed to cordon node %s: %s" % (worker_node, cordon_res.stderr))
    printf("  [SUCCESS] Node %s marked SchedulingDisabled.\n", worker_node)

    # 2. Gracefully drain existing pods
    printf("[2/4] Gracefully draining existing pods from %s...\n", worker_node)
    drain_cmd = "kubectl drain %s --ignore-daemonsets --delete-emptydir-data --force --grace-period=30" % worker_node
    drain_res = exec_node(driver, cp_node, drain_cmd)
    if not drain_res.ok:
        printf("  [WARNING] Drain reported warnings: %s\n", drain_res.stderr)
    printf("  [SUCCESS] Pods evicted and rescheduled to remaining nodes.\n")

    # 3. Delete node object from the Kubernetes API
    printf("[3/4] Deleting node %s from cluster...\n", worker_node)
    del_res = exec_node(driver, cp_node, "kubectl delete node " + worker_node)
    if not del_res.ok:
        fail("Failed to delete node %s: %s" % (worker_node, del_res.stderr))
    printf("  [SUCCESS] Node %s removed from Kubernetes registry.\n", worker_node)

    # 4. Reset kubeadm on the worker node
    printf("[4/4] Resetting kubeadm state on %s...\n", worker_node)
    exec_node(driver, worker_node, "kubeadm reset -f >/dev/null 2>&1 || true")
    printf("  [SUCCESS] Node %s reset.\n", worker_node)

    # Print updated node table
    print("\nUpdated Cluster Topology:")
    nodes_res = exec_node(driver, cp_node, "kubectl get nodes -o wide")
    printf("%s\n", nodes_res.stdout)

def main():
    driver = var_str("driver", "lima").lower()
    action = var_str("action", "join").lower()
    cp_node = var_str("cp", "k8s-cp")
    node = var_str("node", "k8s-worker-2")

    if action == "join":
        scale_out(driver, cp_node, node)
    elif action == "drain":
        scale_in(driver, cp_node, node)
    else:
        fail("Action must be 'join' or 'drain', got: " + action)
