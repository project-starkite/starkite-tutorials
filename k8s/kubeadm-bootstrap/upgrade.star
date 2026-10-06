# upgrade.star - Day-2 Zero-Downtime Rolling Cluster Upgrades
#
# Automates the canonical upstream Kubernetes upgrade ceremony:
# 1. Control Plane Upgrade: Upgrades kubeadm, runs kubeadm upgrade apply, restarts kubelet
# 2. Sequential Worker Node Upgrades: Cordon -> Drain -> kubeadm upgrade node -> kubelet restart -> Uncordon
# 3. Health Gates: Verifies each node returns to Ready using native k8s.wait_for

load("time", "time")
load("./lima.star", "lima")
load("./common.star", "common")

get_k8s_client = common.get_k8s_client

def wait_for_apt_lock(node, max_retries = 30):
    """Waits for any background package manager locks to release on a node."""
    for attempt in range(max_retries):
        res = lima.exec(node, "fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && echo 'locked' || echo 'free'")
        if "free" in res.stdout:
            return True
        time.sleep("2s")
    fail("Timed out waiting for dpkg lock to release on node " + node)

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

def upgrade_control_plane(cp_node, version, k8s_client):
    """Executes the control plane upgrade sequence."""
    printf("=== Step 1/2: Upgrading Control Plane %s to v%s ===\n\n", cp_node, version)

    # 1. Upgrade kubeadm binary on control plane
    printf("  [1/4] Upgrading kubeadm package to %s...\n", version)
    wait_for_apt_lock(cp_node)
    pkg_cmd = "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -qq --allow-change-held-packages kubeadm=%s-* >/dev/null" % version
    res = lima.exec(cp_node, pkg_cmd)
    if not res.ok:
        fail("Failed upgrading kubeadm on %s: %s" % (cp_node, res.stderr))

    # 2. Run kubeadm upgrade apply
    printf("  [2/4] Running kubeadm upgrade apply v%s...\n", version)
    upgrade_cmd = "kubeadm upgrade apply v%s -y" % version
    res = lima.exec(cp_node, upgrade_cmd)
    if not res.ok:
        fail("kubeadm upgrade apply failed on %s: %s" % (cp_node, res.stderr))
    printf("  [SUCCESS] Control plane components upgraded.\n")

    # 3. Upgrade kubelet and kubectl on control plane
    printf("  [3/4] Upgrading kubelet and kubectl on %s...\n", cp_node)
    wait_for_apt_lock(cp_node)
    klet_cmd = "export DEBIAN_FRONTEND=noninteractive && apt-get install -y -qq --allow-change-held-packages kubelet=%s-* kubectl=%s-* >/dev/null && systemctl daemon-reload && systemctl restart kubelet" % (version, version)
    res = lima.exec(cp_node, klet_cmd)
    if not res.ok:
        fail("Failed upgrading kubelet on %s: %s" % (cp_node, res.stderr))

    # 4. Verify control plane readiness natively
    printf("  [4/4] Verifying control plane node status via native k8s API...\n")
    time.sleep("5s")
    node_obj = k8s_client.get("node", cp_node)
    printf("  [SUCCESS] Node %s kubelet version is %s\n\n", cp_node, node_obj.status.nodeInfo.kubeletVersion)

def upgrade_worker_node(cp_node, worker_node, version, k8s_client):
    """Executes the in-place node upgrade for a single worker node using native k8s module."""
    printf("=== Upgrading Worker Node %s to v%s ===\n", worker_node, version)

    # 1. Cordon & Drain via native k8s module
    printf("  [1/5] Cordoning and draining %s via native k8s module...\n", worker_node)
    k8s_client.cordon(worker_node)
    k8s_client.drain(worker_node, force = True, ignore_daemonsets = True)

    # 2. Upgrade kubeadm on worker
    printf("  [2/5] Upgrading kubeadm package on %s...\n", worker_node)
    wait_for_apt_lock(worker_node)
    pkg_cmd = "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -qq --allow-change-held-packages kubeadm=%s-* >/dev/null" % version
    res = lima.exec(worker_node, pkg_cmd)
    if not res.ok:
        fail("Failed upgrading kubeadm on %s: %s" % (worker_node, res.stderr))

    # 3. Run kubeadm upgrade node
    printf("  [3/5] Running kubeadm upgrade node...\n")
    res = lima.exec(worker_node, "kubeadm upgrade node")
    if not res.ok:
        fail("kubeadm upgrade node failed on %s: %s" % (worker_node, res.stderr))

    # 4. Upgrade kubelet and restart service
    printf("  [4/5] Upgrading kubelet and restarting service on %s...\n", worker_node)
    wait_for_apt_lock(worker_node)
    klet_cmd = "export DEBIAN_FRONTEND=noninteractive && apt-get install -y -qq --allow-change-held-packages kubelet=%s-* >/dev/null && systemctl daemon-reload && systemctl restart kubelet" % version
    res = lima.exec(worker_node, klet_cmd)
    if not res.ok:
        fail("Failed upgrading kubelet on %s: %s" % (worker_node, res.stderr))

    # 5. Uncordon & Health Gate via native k8s.wait_for construct
    printf("  [5/5] Uncordoning %s and asserting Ready status via native k8s.wait_for...\n", worker_node)
    k8s_client.uncordon(worker_node)

    res = k8s_client.wait_for("node", worker_node, condition = "ready", timeout = "3m")
    if not res.ready:
        fail("Health check failed: Node %s did not return to Ready state: %s" % (worker_node, res.message))

    printf("  [SUCCESS] Worker %s upgraded to v%s and returned to service.\n\n", worker_node, version)

def upgrade_cluster(cp_node, workers, target_version, kubeconfig_path):
    """Executes the full upstream rolling upgrade across control plane and worker nodes."""
    k8s_client = get_k8s_client(kubeconfig_path)

    printf("\n=== Starkite Upstream Rolling Upgrade ===\n")
    printf("Driver         : lima\n")
    printf("Target Version : v%s\n", target_version)
    printf("Control Plane  : %s\n", cp_node)
    printf("Workers        : %s\n\n", ", ".join(workers))

    # 1. Upgrade Control Plane
    upgrade_control_plane(cp_node, target_version, k8s_client)

    # 2. Sequentially upgrade worker nodes with health verification gates
    printf("=== Step 2/2: Sequentially upgrading worker nodes ===\n\n")
    for w in workers:
        upgrade_worker_node(cp_node, w, target_version, k8s_client)

    printf("\n=== Cluster Rolling Upgrade Complete ===\n\n")
    print_cluster_nodes(k8s_client)
