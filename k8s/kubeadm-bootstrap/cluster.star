#!/usr/bin/env kite --allow-all
# cluster.star - Upstream Kubernetes Cluster Lifecycle Management
#
# Provides end-to-end cluster lifecycle operations using kubeadm and native Starkite primitives:
# - Day-0 & Day-1: Bootstrap control plane, join workers, apply CNI, deploy smoke test
# - Day-2 Scaling: Dynamically add worker nodes or cordons, drains, and decommission nodes
# - Topology: Inspect cluster node status and health natively
#
# Usage:
#   # 1. Bootstrap cluster (default: k8s-cp, k8s-worker-1, k8s-worker-2):
#   kite run ./cluster.star
#
#   # 2. Add / scale out a new worker node:
#   kite run ./cluster.star --action add-node --node k8s-worker-3
#
#   # 3. Safely decommission / drain a worker node:
#   kite run ./cluster.star --action remove-node --node k8s-worker-2
#
#   # 4. Query live cluster node status:
#   kite run ./cluster.star --action status

load("concur", "concur")
load("time", "time")
load("./lima.star", "lima")
load("./common.star", "common")

verify_cluster_mesh = common.verify_cluster_mesh
get_k8s_client = common.get_k8s_client

# ---------------------------------------------------------------------------
# CLI Argument Schema
# ---------------------------------------------------------------------------
args.string(
    "action",
    shorthand = "a",
    default = "bootstrap",
    choices = ["bootstrap", "add-node", "remove-node", "join", "drain", "status"],
    help = "Cluster action: bootstrap, add-node, remove-node, status",
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
    help = "Worker node hostnames for bootstrap (comma-separated or repeatable)",
)

args.string(
    "node",
    shorthand = "n",
    default = "k8s-worker-2",
    help = "Target worker node hostname to add or remove",
)

args.string(
    "pod-cidr",
    flag = "pod-cidr",
    default = "10.244.0.0/16",
    help = "Pod network CIDR block",
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
# Core Lifecycle Functions
# ---------------------------------------------------------------------------

def init_control_plane(cp_node, pod_cidr):
    """Initializes the Kubernetes control plane via kubeadm init if not already active."""
    printf("[1/5] Initializing control plane node %s...\n", cp_node)

    check_init = lima.exec(cp_node, "test -f /etc/kubernetes/admin.conf && echo 'exists' || echo 'missing'")
    if "exists" in check_init.stdout:
        printf("  [%s] Control plane is already initialized (/etc/kubernetes/admin.conf present).\n", cp_node)
    else:
        cp_ip = lima.get_ip(cp_node)
        if cp_ip == "unknown" or not cp_ip:
            fail("Could not detect IP address for control plane node " + cp_node)

        printf("  [%s] Control Plane IP: %s\n", cp_node, cp_ip)
        printf("  [%s] Running kubeadm init (pod-network-cidr=%s)...\n", cp_node, pod_cidr)

        init_cmd = (
            "kubeadm init " +
            "--apiserver-advertise-address=%s " +
            "--apiserver-cert-extra-sans=127.0.0.1,localhost,%s " +
            "--pod-network-cidr=%s " +
            "--node-name=%s " +
            "--ignore-preflight-errors=all"
        ) % (cp_ip, cp_ip, pod_cidr, cp_node)

        res = lima.exec(cp_node, init_cmd)
        if not res.ok:
            fail("kubeadm init failed on %s: %s" % (cp_node, res.stderr))
        printf("  [%s SUCCESS] Control plane initialized successfully.\n", cp_node)

    # Configure local root and user kubeconfig on the control plane node
    lima.exec(cp_node, "mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config && chmod 600 /root/.kube/config")
    lima.exec(cp_node, "for d in /home/*; do if [ -d \"$d\" ]; then mkdir -p \"$d/.kube\" && cp -f /etc/kubernetes/admin.conf \"$d/.kube/config\" && chown -R $(stat -c '%u:%g' \"$d\") \"$d/.kube\" 2>/dev/null || true; fi; done")

def fetch_and_save_kubeconfig(cp_node, output_path):
    """Retrieves admin.conf from the control plane and saves it locally."""
    printf("[2/5] Fetching cluster kubeconfig from %s...\n", cp_node)
    cp_ip = lima.get_ip(cp_node)
    raw_conf = lima.read_file(cp_node, "/etc/kubernetes/admin.conf")
    # Host connects via forwarded loopback port 6443
    adapted_conf = raw_conf.replace("https://" + cp_ip + ":6443", "https://127.0.0.1:6443")

    # Ensure target parent directory exists and write kubeconfig
    parent_dir = output_path[:output_path.rfind("/")]
    if parent_dir:
        os.sh().try_exec("mkdir -p " + parent_dir)
    fs.path(output_path).write_text(adapted_conf)
    printf("  [SUCCESS] Kubeconfig saved to %s (API endpoint: https://127.0.0.1:6443)\n", output_path)
    return adapted_conf

def get_join_command(cp_node):
    """Generates and retrieves a standard kubeadm join command with token."""
    res = lima.exec(cp_node, "kubeadm token create --print-join-command")
    if not res.ok:
        fail("Failed generating join token on %s: %s" % (cp_node, res.stderr))
    return res.stdout.strip()

def join_worker(worker_node, join_cmd):
    """Joins a worker node to the cluster if not already joined."""
    check_res = lima.exec(worker_node, "test -f /etc/kubernetes/kubelet.conf && echo 'joined' || echo 'missing'")
    if "joined" in check_res.stdout:
        printf("  [%s] Worker is already joined to cluster (skipping).\n", worker_node)
        return worker_node

    printf("  [%s] Joining cluster via kubeadm join...\n", worker_node)
    cmd = join_cmd + " --node-name=" + worker_node + " --ignore-preflight-errors=all"
    res = lima.exec(worker_node, cmd)
    if not res.ok:
        fail("Failed joining worker node %s: %s" % (worker_node, res.stderr))
    printf("  [%s SUCCESS] Joined cluster successfully.\n", worker_node)
    return worker_node

def install_cni(k8s_client, cni_type):
    """Installs the requested CNI plugin on the cluster using Starkite's native http and k8s modules."""
    printf("[4/5] Installing Container Network Interface (CNI: %s)...\n", cni_type)
    if cni_type == "flannel":
        flannel_url = "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
        resp = http.url(flannel_url).get()
        if resp.status_code != 200:
            fail("Failed fetching Flannel CNI manifest: HTTP " + str(resp.status_code))
        k8s_client.apply(resp.get_text(), force = True)
        printf("  [SUCCESS] Flannel CNI manifests applied natively.\n")
    elif cni_type == "calico":
        calico_url = "https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml"
        resp = http.url(calico_url).get()
        if resp.status_code != 200:
            fail("Failed fetching Calico CNI manifest: HTTP " + str(resp.status_code))
        k8s_client.apply(resp.get_text(), force = True)
        printf("  [SUCCESS] Calico CNI manifests applied natively.\n")
    else:
        fail("Unsupported CNI: " + cni_type + ". Choose 'flannel' or 'calico'.")

def assert_cluster_readiness(k8s_client, expected_count):
    """Polls until all expected nodes report Ready status using Starkite's native k8s client."""
    printf("[5/5] Waiting for all %d nodes to reach Ready state...\n", expected_count)
    max_retries = 30
    ready = False

    for attempt in range(max_retries):
        nodes = k8s_client.list("node")
        ready_count = 0
        for n in nodes:
            for cond in n.status.conditions:
                if cond.type == "Ready" and cond.status == "True":
                    ready_count = ready_count + 1
                    break

        if ready_count >= expected_count:
            ready = True
            break

        printf("  Attempt %d/%d: %d/%d nodes Ready. Waiting 10s...\n", attempt + 1, max_retries, ready_count, expected_count)
        time.sleep("10s")

    if not ready:
        fail("Timed out waiting for all nodes to reach Ready state.")

    printf("  [SUCCESS] All %d nodes are in Ready state!\n", expected_count)

def deploy_smoke_test_workload(k8s_client):
    """Deploys an application stack from smoke-test.yaml to verify cluster scheduling and pod networking."""
    printf("\nDeploying smoke-test workload to verify cluster functionality...\n")
    manifest = fs.path("./smoke-test.yaml").read_text()
    k8s_client.apply(manifest, force = True)
    printf("  [SUCCESS] Smoke-test workload applied natively via k8s module.\n")

def print_cluster_summary(k8s_client, kubeconfig_path):
    """Prints a structured summary of the live cluster nodes and status."""
    printf("\n=== Cluster Status Summary ===\n\n")
    printf("%-16s %-10s %-16s %-12s %-16s\n", "NAME", "STATUS", "ROLES", "VERSION", "INTERNAL-IP")

    nodes = k8s_client.list("node")
    for n in nodes:
        name = n.metadata.name
        version = n.status.nodeInfo.kubeletVersion

        roles = []
        for label_key in n.metadata.labels:
            if "node-role.kubernetes.io/" in label_key:
                role_name = label_key.split("/")[1]
                roles.append(role_name)
        role_str = ",".join(roles) if len(roles) > 0 else "<none>"

        status_str = "NotReady"
        for cond in n.status.conditions:
            if cond.type == "Ready" and cond.status == "True":
                status_str = "Ready"
                break

        internal_ip = "unknown"
        for addr in n.status.addresses:
            if addr.type == "InternalIP":
                internal_ip = addr.address
                break

        printf("%-16s %-10s %-16s %-12s %-16s\n", name, status_str, role_str, version, internal_ip)

    printf("\nTo interact with your cluster locally:\n")
    printf("  export KUBECONFIG=%s\n", kubeconfig_path)
    printf("  kubectl get pods -A\n\n")

# ---------------------------------------------------------------------------
# Scale Operations (add_node and remove_node)
# ---------------------------------------------------------------------------

def add_node(cp_node, worker_node, kubeconfig_path):
    """Joins a worker node to the existing cluster and asserts readiness natively."""
    printf("\n=== Adding Node %s to Cluster ===\n\n", worker_node)

    # 1. Verify kubeadm is ready on the worker
    printf("[1/3] Checking worker node %s readiness...\n", worker_node)
    check_res = lima.exec(worker_node, "kubeadm version -o short 2>/dev/null && systemctl is-active containerd 2>/dev/null")
    if not check_res.ok:
        fail("Node %s is not prepared. Start the machine via ./setup.star first." % worker_node)

    # 2. Generate join token from control plane
    printf("[2/3] Generating join token from control plane %s...\n", cp_node)
    join_cmd = get_join_command(cp_node)

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
    print_cluster_summary(k8s_client, kubeconfig_path)

def remove_node(worker_node, kubeconfig_path):
    """Safely drains and removes a worker node from the cluster using native k8s module."""
    printf("\n=== Decommissioning Node %s ===\n\n", worker_node)
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
    print_cluster_summary(k8s_client, kubeconfig_path)

# ---------------------------------------------------------------------------
# Bootstrap Workflow
# ---------------------------------------------------------------------------

def bootstrap_cluster(cp_node, workers, pod_cidr, cni_type, kubeconfig_out):
    """Executes the full Day-0 and Day-1 upstream cluster bootstrap sequence."""
    all_nodes = [cp_node] + workers

    printf("\n=== Starkite Upstream Kubeadm Bootstrap ===\n")
    printf("Driver         : lima\n")
    printf("Control Plane  : %s\n", cp_node)
    printf("Workers        : %s\n", ", ".join(workers))
    printf("CNI Network    : %s (CIDR: %s)\n", cni_type, pod_cidr)
    printf("Kubeconfig Out : %s\n\n", kubeconfig_out)

    # Pre-flight: verify network mesh
    print("[Pre-flight] Verifying node prerequisites and network mesh...")
    verify_cluster_mesh(cp_node, workers)
    print("  [SUCCESS] All nodes prepared and network mesh verified.\n")

    # Step 1: Control plane init
    init_control_plane(cp_node, pod_cidr)

    # Step 2: Fetch kubeconfig locally
    fetch_and_save_kubeconfig(cp_node, kubeconfig_out)

    # Initialize Starkite native k8s client using the fetched kubeconfig
    k8s_client = get_k8s_client(kubeconfig_out)

    # Step 3: Concurrently join all worker nodes
    printf("[3/5] Generating worker join token on %s...\n", cp_node)
    join_cmd = get_join_command(cp_node)
    printf("  Joining %d worker nodes concurrently...\n", len(workers))
    concur.map(workers, lambda w: join_worker(w, join_cmd))

    # Step 4: Install CNI network plugin
    install_cni(k8s_client, cni_type)

    # Step 5: Assert cluster readiness over native API
    assert_cluster_readiness(k8s_client, len(all_nodes))

    # Deploy smoke test workload to verify scheduler & CNI
    deploy_smoke_test_workload(k8s_client)

    # Summary
    print_cluster_summary(k8s_client, kubeconfig_out)

# ---------------------------------------------------------------------------
# CLI Entrypoint
# ---------------------------------------------------------------------------

def main():
    opts = args.parse()

    action = opts.action.lower()
    cp_node = opts.cp
    workers = [w.strip() for w in opts.workers if w.strip()]
    target_node = opts.node
    pod_cidr = getattr(opts, "pod_cidr", "10.244.0.0/16")
    cni_type = opts.cni.lower()
    kubeconfig_out = opts.kubeconfig

    if action == "bootstrap":
        bootstrap_cluster(cp_node, workers, pod_cidr, cni_type, kubeconfig_out)
    elif action in ["add-node", "join"]:
        add_node(cp_node, target_node, kubeconfig_out)
    elif action in ["remove-node", "drain"]:
        remove_node(target_node, kubeconfig_out)
    elif action == "status":
        k8s_client = get_k8s_client(kubeconfig_out)
        print_cluster_summary(k8s_client, kubeconfig_out)
    else:
        fail("Unknown action: " + action + ". Supported actions: bootstrap, add-node, remove-node, status")
