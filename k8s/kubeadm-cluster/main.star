#!/usr/bin/env kite --allow-all
# main.star - Unified CLI Entrypoint for Upstream Kubernetes Cluster Lifecycle
#
# Aggregates all CLI operations for the upstream Kubernetes kubeadm cluster:
# - Machine Provisioning: Launch & configure Lima VMs with containerd & kubeadm (action=setup)
# - Cluster Bootstrap: Day-0 & Day-1 kubeadm init, worker joins, CNI, smoke test (action=bootstrap)
# - Node Scaling: Day-2 dynamic worker join (action=add-node) and decommissioning (action=remove-node)
# - Rolling Upgrade: Day-2 in-place zero-downtime cluster upgrade (action=upgrade)
# - Inspection & Teardown: Unified status check, VM stop, and destroy actions
#
# Usage:
#   # 1. Provision and start virtual machines:
#   ./main.star --action setup
#
#   # 2. Bootstrap upstream Kubernetes cluster:
#   ./main.star --action bootstrap
#
#   # 3. Query combined machine and cluster health:
#   ./main.star --action status
#
#   # 4. Scale out: Add a new worker node:
#   ./main.star --action add-node --node k8s-worker-3
#
#   # 5. Scale in: Safely cordon, drain, and remove a worker node:
#   ./main.star --action remove-node --node k8s-worker-2
#
#   # 6. Rolling upgrade cluster:
#   ./main.star --action upgrade --version 1.31.2
#
#   # 7. Stop or destroy machines:
#   ./main.star --action stop
#   ./main.star --action destroy

load("./lima.star", "lima")
load("./setup.star", "setup")
load("./cluster.star", "cluster")

# ---------------------------------------------------------------------------
# Consolidated CLI Argument Schema
# ---------------------------------------------------------------------------
args.string(
    "action",
    shorthand = "a",
    default = "status",
    choices = [
        "setup", "start",
        "bootstrap",
        "add-node", "join",
        "remove-node", "drain",
        "upgrade",
        "status",
        "stop",
        "destroy",
    ],
    help = "Action: setup, bootstrap, add-node, remove-node, upgrade, status, stop, destroy",
)

args.string(
    "version",
    shorthand = "v",
    default = "1.31",
    help = "Kubernetes minor version (e.g. 1.31 for setup) or target version (e.g. 1.31.2 for upgrade)",
)

args.string(
    "cp",
    default = "k8s-cp",
    help = "Control plane node machine name",
)

args.list(
    "workers",
    shorthand = "w",
    default = ["k8s-worker-1", "k8s-worker-2"],
    item_type = "string",
    help = "Worker node hostnames (comma-separated or repeatable)",
)

args.string(
    "node",
    shorthand = "n",
    default = "k8s-worker-2",
    help = "Target worker node hostname for add-node or remove-node",
)

args.int(
    "cpus",
    default = 2,
    help = "Virtual CPUs allocated per node",
)

args.int(
    "memory",
    default = 2,
    help = "RAM in GiB allocated per node",
)

args.int(
    "disk",
    default = 20,
    help = "Disk space in GiB allocated per node",
)

args.string(
    "pod-cidr",
    flag = "pod-cidr",
    default = "10.244.0.0/16",
    help = "Pod network CIDR block for bootstrap",
)

args.string(
    "cni",
    default = "flannel",
    choices = ["flannel", "calico"],
    help = "CNI network plugin to install (flannel or calico)",
)

args.string(
    "kubeconfig",
    shorthand = "k",
    default = lima.get_kubeconfig_path(),
    help = "Path to cluster admin kubeconfig file",
)

# ---------------------------------------------------------------------------
# Main Routing Entrypoint
# ---------------------------------------------------------------------------

def main():
    opts = args.parse()

    action = opts.action.lower()
    k8s_ver = opts.version
    cp_node = opts.cp
    workers = [w.strip() for w in opts.workers if w.strip()]
    target_node = opts.node
    cpus = opts.cpus
    memory_gb = opts.memory
    disk_gb = opts.disk
    pod_cidr = getattr(opts, "pod_cidr", "10.244.0.0/16")
    cni_type = opts.cni.lower()
    kubeconfig_out = opts.kubeconfig

    all_nodes = [cp_node] + workers

    if action in ["setup", "start"]:
        setup.start_nodes(all_nodes, cp_node, cpus, memory_gb, disk_gb, k8s_ver)

    elif action == "bootstrap":
        cluster.bootstrap_cluster(cp_node, workers, pod_cidr, cni_type, kubeconfig_out)

    elif action in ["add-node", "join"]:
        cluster.add_node(cp_node, target_node, kubeconfig_out)

    elif action in ["remove-node", "drain"]:
        cluster.remove_node(target_node, kubeconfig_out)

    elif action == "upgrade":
        cluster.upgrade_cluster(cp_node, workers, k8s_ver, kubeconfig_out)

    elif action == "status":
        printf("\n=== Starkite Kubeadm Environment Status ===\n\n")
        setup.show_machine_status(all_nodes)
        if lima.get_status(cp_node) == "Running":
            cluster.show_cluster_status(kubeconfig_out)
        else:
            printf("Cluster API is offline (control plane %s is not running).\n\n", cp_node)

    elif action == "stop":
        setup.stop_nodes(all_nodes)

    elif action == "destroy":
        setup.destroy_nodes(all_nodes)

    else:
        fail("Unknown action: " + action + ". Supported actions: setup, bootstrap, add-node, remove-node, upgrade, status, stop, destroy")
