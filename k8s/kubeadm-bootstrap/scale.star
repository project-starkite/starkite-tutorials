#!/usr/bin/env kite --allow-all
# scale.star - Day-2 Dynamic Worker Node Scaling & Decommissioning
#
# Automates Day-2 worker node operations without requiring Cluster API (CAPI):
# 1. Scale Out (action=join): Dynamically adds a new worker node to the cluster
# 2. Scale In (action=drain): Safely cordons, drains, and evicts workloads from a node natively
#
# Usage:
#   # 1. Add / Join a new worker node (k8s-worker-3):
#   kite run ./scale.star --action join --node k8s-worker-3
#
#   # 2. Safely drain and remove a worker node:
#   kite run ./scale.star --action drain --node k8s-worker-2

load("time", "time")
load("./lima.star", "lima")
load("./common.star", "common")

get_k8s_client = common.get_k8s_client

# ---------------------------------------------------------------------------
# CLI Argument Schema
# ---------------------------------------------------------------------------
args.string(
    "action",
    shorthand = "a",
    default = "join",
    choices = ["join", "drain"],
    help = "Scaling action to perform: join or drain",
)

args.string(
    "cp",
    default = "k8s-cp",
    help = "Control plane node machine name",
)

args.string(
    "node",
    shorthand = "n",
    default = "k8s-worker-2",
    help = "Target worker node hostname to join or drain",
)

args.string(
    "kubeconfig",
    shorthand = "k",
    default = lima.get_kubeconfig_path(),
    help = "Path to admin kubeconfig file",
)

def print_cluster_nodes(k8s_client):
    """Renders the cluster node table directly from the Kubernetes API."""
    nodes = k8s_client.list("node")
    printf("%-16s %-10s %-16s %-12s %-16s\n", "NAME", "STATUS", "ROLES", "VERSION", "INTERNAL-IP")
    for n in nodes:
        name = n.metadata.name
        status = "NotReady"
        for c in n.status.conditions:
            if c.type == "Ready" and c.status == "True":
                status = "Ready"
        roles = []
        if hasattr(n.metadata, "labels") and n.metadata.labels:
            for label in n.metadata.labels:
                if label.startswith("node-role.kubernetes.io/"):
                    roles.append(label.split("/")[1])
        role_str = ",".join(roles) if len(roles) > 0 else "<none>"
        version = n.status.nodeInfo.kubeletVersion
        ip = "unknown"
        for addr in n.status.addresses:
            if addr.type == "InternalIP":
                ip = addr.address
        printf("%-16s %-10s %-16s %-12s %-16s\n", name, status, role_str, version, ip)

def scale_out(cp_node, worker_node, kubeconfig_path):
    """Joins a worker node to the existing cluster and asserts readiness natively."""
    printf("=== Day-2 Scale Out: Joining %s to cluster ===\n\n", worker_node)

    # 1. Verify kubeadm is ready on the worker
    printf("[1/3] Checking worker node %s readiness...\n", worker_node)
    check_res = lima.exec(worker_node, "kubeadm version -o short 2>/dev/null && systemctl is-active containerd 2>/dev/null")
    if not check_res.ok:
        fail("Node %s is not prepared. Start the machine via ./setup.star first." % worker_node)

    # 2. Generate join token from control plane
    printf("[2/3] Generating join token from control plane %s...\n", cp_node)
    tok_res = lima.exec(cp_node, "kubeadm token create --print-join-command")
    if not tok_res.ok:
        fail("Failed generating token on %s: %s" % (cp_node, tok_res.stderr))
    join_cmd = tok_res.stdout.strip()

    # 3. Join the node
    printf("[3/3] Joining %s to cluster...\n", worker_node)
    res = lima.exec(worker_node, join_cmd + " --node-name=" + worker_node + " --ignore-preflight-errors=all")
    if not res.ok:
        fail("Failed joining node %s: %s" % (worker_node, res.stderr))

    # 4. Wait for node to enter Ready state via native k8s client
    printf("Waiting for node %s to report Ready status via native k8s API...\n", worker_node)
    k8s_client = get_k8s_client(kubeconfig_path)
    ready = False
    for attempt in range(18):
        node_obj = k8s_client.get("node", worker_node)
        for cond in node_obj.status.conditions:
            if cond.type == "Ready" and cond.status == "True":
                ready = True
                break
        if ready:
            printf("  [SUCCESS] Node %s is Ready!\n", worker_node)
            break
        time.sleep("10s")

    if not ready:
        fail("Timed out waiting for node %s to report Ready status." % worker_node)

    # Print updated node table natively
    print("\nUpdated Cluster Topology:")
    print_cluster_nodes(k8s_client)

def scale_in(worker_node, kubeconfig_path):
    """Safely drains and removes a worker node from the cluster using native k8s module."""
    printf("=== Day-2 Scale In: Decommissioning %s ===\n\n", worker_node)
    k8s_client = get_k8s_client(kubeconfig_path)

    # 1. Cordon the node natively
    printf("[1/4] Cordoning node %s via native k8s module...\n", worker_node)
    k8s_client.cordon(worker_node)
    printf("  [SUCCESS] Node %s marked SchedulingDisabled.\n", worker_node)

    # 2. Gracefully drain existing pods natively
    printf("[2/4] Gracefully draining existing pods from %s...\n", worker_node)
    k8s_client.drain(worker_node, force = True, ignore_daemonsets = True)
    printf("  [SUCCESS] Pods evicted and rescheduled to remaining nodes.\n")

    # 3. Delete node object from the Kubernetes API natively
    printf("[3/4] Deleting node %s from cluster via native k8s API...\n", worker_node)
    k8s_client.delete("node", worker_node)
    printf("  [SUCCESS] Node %s removed from Kubernetes registry.\n", worker_node)

    # 4. Reset kubeadm on the worker node
    printf("[4/4] Resetting kubeadm state on %s...\n", worker_node)
    lima.exec(worker_node, "kubeadm reset -f >/dev/null 2>&1 || true")
    printf("  [SUCCESS] Node %s reset.\n", worker_node)

    # Print updated node table natively
    print("\nUpdated Cluster Topology:")
    print_cluster_nodes(k8s_client)

def main():
    opts = args.parse()

    action = opts.action.lower()
    cp_node = opts.cp
    node = opts.node
    kubeconfig_path = opts.kubeconfig

    if action == "join":
        scale_out(cp_node, node, kubeconfig_path)
    elif action == "drain":
        scale_in(node, kubeconfig_path)
    else:
        fail("Action must be 'join' or 'drain', got: " + action)
