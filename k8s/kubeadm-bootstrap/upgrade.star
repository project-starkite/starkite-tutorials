#!/usr/bin/env kite --allow-all
# upgrade.star - Day-2 Zero-Downtime Rolling Cluster Upgrades
#
# Automates the canonical upstream Kubernetes upgrade ceremony:
# 1. Control Plane Upgrade: Upgrades kubeadm, runs kubeadm upgrade apply, restarts kubelet
# 2. Sequential Worker Node Upgrades: Cordon -> Drain -> kubeadm upgrade node -> kubelet restart -> Uncordon
# 3. Health Gates: Verifies each node returns to Ready before upgrading the next node
#
# Usage:
#   # Upgrade cluster to target version:
#   kite run ./upgrade.star --version 1.31.2 --driver lima

load("time", "time")
load("./common.star", "common")

exec_node = common.exec_node
run_local = common.run_local

# ---------------------------------------------------------------------------
# CLI Argument Schema
# ---------------------------------------------------------------------------
args.string(
    "driver",
    shorthand = "d",
    default = "lima",
    choices = ["lima", "multipass"],
    help = "Virtualization driver: lima (limactl) or multipass",
)

args.string(
    "version",
    shorthand = "v",
    default = "1.31.2",
    help = "Target Kubernetes version for upgrade (e.g. 1.31.2)",
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
    help = "Worker node hostnames to upgrade sequentially (comma-separated or repeatable)",
)

def upgrade_control_plane(driver, cp_node, version):
    """Executes the control plane upgrade sequence."""
    printf("=== Step 1/2: Upgrading Control Plane %s to v%s ===\n\n", cp_node, version)

    # 1. Upgrade kubeadm binary on control plane
    printf("  [1/4] Upgrading kubeadm package to %s...\n", version)
    pkg_cmd = "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -qq --allow-change-held-packages kubeadm=%s-* >/dev/null" % version
    res = exec_node(driver, cp_node, pkg_cmd)
    if not res.ok:
        fail("Failed upgrading kubeadm on %s: %s" % (cp_node, res.stderr))

    # 2. Run kubeadm upgrade apply
    printf("  [2/4] Running kubeadm upgrade apply v%s...\n", version)
    upgrade_cmd = "kubeadm upgrade apply v%s -y" % version
    res = exec_node(driver, cp_node, upgrade_cmd)
    if not res.ok:
        fail("kubeadm upgrade apply failed on %s: %s" % (cp_node, res.stderr))
    printf("  [SUCCESS] Control plane plane components upgraded.\n")

    # 3. Upgrade kubelet and kubectl on control plane
    printf("  [3/4] Upgrading kubelet and kubectl on %s...\n", cp_node)
    klet_cmd = "export DEBIAN_FRONTEND=noninteractive && apt-get install -y -qq --allow-change-held-packages kubelet=%s-* kubectl=%s-* >/dev/null && systemctl daemon-reload && systemctl restart kubelet" % (version, version)
    res = exec_node(driver, cp_node, klet_cmd)
    if not res.ok:
        fail("Failed upgrading kubelet on %s: %s" % (cp_node, res.stderr))

    # 4. Verify control plane readiness
    printf("  [4/4] Verifying control plane node status...\n")
    time.sleep(5)
    ver_res = exec_node(driver, cp_node, "kubectl get node %s" % cp_node)
    printf("%s\n", ver_res.stdout)

def upgrade_worker_node(driver, cp_node, worker_node, version):
    """Executes the in-place node upgrade for a single worker node."""
    printf("=== Upgrading Worker Node %s to v%s ===\n", worker_node, version)

    # 1. Cordon & Drain
    printf("  [1/5] Cordoning and draining %s...\n", worker_node)
    exec_node(driver, cp_node, "kubectl cordon " + worker_node)
    drain_cmd = "kubectl drain %s --ignore-daemonsets --delete-emptydir-data --force --grace-period=30" % worker_node
    exec_node(driver, cp_node, drain_cmd)

    # 2. Upgrade kubeadm on worker
    printf("  [2/5] Upgrading kubeadm package on %s...\n", worker_node)
    pkg_cmd = "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -qq --allow-change-held-packages kubeadm=%s-* >/dev/null" % version
    res = exec_node(driver, worker_node, pkg_cmd)
    if not res.ok:
        fail("Failed upgrading kubeadm on %s: %s" % (worker_node, res.stderr))

    # 3. Run kubeadm upgrade node
    printf("  [3/5] Running kubeadm upgrade node...\n")
    res = exec_node(driver, worker_node, "kubeadm upgrade node")
    if not res.ok:
        fail("kubeadm upgrade node failed on %s: %s" % (worker_node, res.stderr))

    # 4. Upgrade kubelet and restart service
    printf("  [4/5] Upgrading kubelet and restarting service on %s...\n", worker_node)
    klet_cmd = "export DEBIAN_FRONTEND=noninteractive && apt-get install -y -qq --allow-change-held-packages kubelet=%s-* >/dev/null && systemctl daemon-reload && systemctl restart kubelet" % version
    res = exec_node(driver, worker_node, klet_cmd)
    if not res.ok:
        fail("Failed upgrading kubelet on %s: %s" % (worker_node, res.stderr))

    # 5. Uncordon & Health Gate
    printf("  [5/5] Uncordoning %s and asserting Ready status...\n", worker_node)
    exec_node(driver, cp_node, "kubectl uncordon " + worker_node)

    ready = False
    for attempt in range(18):
        status_res = exec_node(driver, cp_node, "kubectl get node %s --no-headers" % worker_node)
        if "Ready" in status_res.stdout and "NotReady" not in status_res.stdout:
            ready = True
            break
        time.sleep(10)

    if not ready:
        fail("Health check failed: Node %s did not return to Ready state." % worker_node)

    printf("  [SUCCESS] Worker %s upgraded to v%s and returned to service.\n\n", worker_node, version)

def main():
    opts = args.parse()

    driver = opts.driver.lower()
    target_version = opts.version
    cp_node = opts.cp
    workers = [w.strip() for w in opts.workers if w.strip()]

    printf("\n=== Starkite Upstream Rolling Upgrade ===\n")
    printf("Driver         : %s\n", driver)
    printf("Target Version : v%s\n", target_version)
    printf("Control Plane  : %s\n", cp_node)
    printf("Workers        : %s\n\n", ", ".join(workers))

    # 1. Upgrade Control Plane
    upgrade_control_plane(driver, cp_node, target_version)

    # 2. Sequentially upgrade worker nodes with health verification gates
    printf("=== Step 2/2: Sequentially upgrading worker nodes ===\n\n")
    for w in workers:
        upgrade_worker_node(driver, cp_node, w, target_version)

    printf("\n=== Cluster Rolling Upgrade Complete ===\n\n")
    nodes_res = exec_node(driver, cp_node, "kubectl get nodes -o wide")
    printf("%s\n", nodes_res.stdout)
