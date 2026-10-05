#!/usr/bin/env kite --allow-all
# bootstrap.star - Day-0 & Day-1 Upstream Kubernetes Cluster Bootstrap
#
# Automates the end-to-end initialization of an upstream Kubernetes cluster using kubeadm:
# 1. Pre-flight verification across control plane and worker nodes
# 2. Control plane initialization via `kubeadm init`
# 3. Kubeconfig retrieval and local artifact emission
# 4. Dynamic cluster join command extraction and concurrent worker join (via concur.map)
# 5. CNI network plugin installation (Flannel / Calico)
# 6. Cluster readiness assertion (polling until all nodes reach Ready)
#
# Usage:
#   # 1. Bootstrap cluster on Lima VMs (default):
#   kite run ./bootstrap.star --driver lima
#
#   # 2. Bootstrap cluster on Multipass VMs:
#   kite run ./bootstrap.star --driver multipass
#
#   # 3. Specify custom node names or CNI:
#   kite run ./bootstrap.star --driver lima --cp k8s-cp --workers k8s-worker-1,k8s-worker-2 --cni flannel

load("concur", "concur")
load("http", "http")
load("time", "time")
load("./common.star", "common")

exec_node = common.exec_node
get_node_ip = common.get_node_ip
run_local = common.run_local
verify_cluster_mesh = common.verify_cluster_mesh
get_k8s_client = common.get_k8s_client

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
    "pod-cidr",
    flag = "pod-cidr",
    default = "10.244.0.0/16",
    help = "Pod network CIDR range",
)

args.string(
    "cni",
    default = "flannel",
    choices = ["flannel", "calico"],
    help = "Container Network Interface plugin (flannel or calico)",
)

args.string(
    "kubeconfig",
    shorthand = "k",
    default = "./kubeconfig",
    help = "Destination path for generated admin kubeconfig",
)

def check_node_ready_for_bootstrap(driver, node):
    """Verifies that kubeadm and containerd are installed and running on a node."""
    res = exec_node(driver, node, "kubeadm version -o short && systemctl is-active containerd")
    if not res.ok:
        fail("Node %s is not prepared. Run ./setup.star first. Error: %s" % (node, res.stderr))
    return True

def init_control_plane(driver, cp_node, pod_cidr):
    """Initializes the Kubernetes control plane node using kubeadm init."""
    printf("[1/5] Initializing control plane node %s...\n", cp_node)

    # Check if control plane is already initialized
    check_init = exec_node(driver, cp_node, "test -f /etc/kubernetes/admin.conf && echo 'exists' || echo 'missing'")
    if "exists" in check_init.stdout:
        printf("  [%s] Control plane is already initialized (/etc/kubernetes/admin.conf present).\n", cp_node)
    else:
        cp_ip = get_node_ip(driver, cp_node)
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

        res = exec_node(driver, cp_node, init_cmd)
        if not res.ok:
            fail("kubeadm init failed on %s: %s" % (cp_node, res.stderr))
        printf("  [%s SUCCESS] Control plane initialized successfully.\n", cp_node)

    # Configure local root and user kubeconfig on the control plane node
    exec_node(driver, cp_node, "mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config && chmod 600 /root/.kube/config")
    exec_node(driver, cp_node, "for d in /home/*; do if [ -d \"$d\" ]; then mkdir -p \"$d/.kube\" && cp -f /etc/kubernetes/admin.conf \"$d/.kube/config\" && chown -R $(stat -c '%u:%g' \"$d\") \"$d/.kube\" 2>/dev/null || true; fi; done")

def fetch_and_save_kubeconfig(driver, cp_node, output_path):
    """Retrieves admin.conf from the control plane and saves it locally."""
    printf("[2/5] Fetching cluster kubeconfig from %s...\n", cp_node)
    cp_ip = get_node_ip(driver, cp_node)
    conf_res = exec_node(driver, cp_node, "cat /etc/kubernetes/admin.conf")
    if not conf_res.ok:
        fail("Failed retrieving admin.conf from %s: %s" % (cp_node, conf_res.stderr))

    raw_conf = conf_res.stdout
    # Point the server endpoint: for Lima, host connects via forwarded 127.0.0.1; for Multipass, host connects via cp_ip
    server_host = "127.0.0.1" if driver == "lima" else cp_ip
    adapted_conf = raw_conf.replace("https://" + cp_ip + ":6443", "https://" + server_host + ":6443")
    adapted_conf = adapted_conf.replace("https://127.0.0.1:6443", "https://" + server_host + ":6443")
    
    # Save to local file
    write_text(output_path, adapted_conf)
    printf("  [SUCCESS] Kubeconfig saved to %s (API endpoint: https://%s:6443)\n", output_path, server_host)
    return adapted_conf

def get_join_command(driver, cp_node):
    """Generates and retrieves a standard kubeadm join command with token."""
    printf("[3/5] Generating worker join token on %s...\n", cp_node)
    res = exec_node(driver, cp_node, "kubeadm token create --print-join-command")
    if not res.ok:
        fail("Failed generating join token on %s: %s" % (cp_node, res.stderr))
    join_cmd = res.stdout.strip()
    return join_cmd

def join_worker_node(driver, worker_node, join_cmd):
    """Joins a worker node to the cluster."""
    check_res = exec_node(driver, worker_node, "test -f /etc/kubernetes/kubelet.conf && echo 'joined' || echo 'missing'")
    if "joined" in check_res.stdout:
        printf("  [%s] Worker is already joined to cluster (skipping).\n", worker_node)
        return worker_node

    printf("  [%s] Joining cluster via kubeadm join...\n", worker_node)
    cmd = join_cmd + " --node-name=" + worker_node + " --ignore-preflight-errors=all"
    res = exec_node(driver, worker_node, cmd)
    if not res.ok:
        fail("Failed joining worker node %s: %s" % (worker_node, res.stderr))
    printf("  [%s SUCCESS] Joined cluster successfully.\n", worker_node)
    return worker_node

def install_cni(k8s_client, cni_type):
    """Installs the requested CNI plugin on the cluster using Starkite's native http and k8s modules."""
    printf("[4/5] Installing Container Network Interface (CNI: %s)...\n", cni_type)
    if cni_type == "flannel":
        flannel_url = "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
        resp = http.get(flannel_url)
        if resp.status_code != 200:
            fail("Failed fetching Flannel CNI manifest: HTTP " + str(resp.status_code))
        k8s_client.apply(resp.get_text(), force=True)
        printf("  [SUCCESS] Flannel CNI manifests applied natively.\n")
    elif cni_type == "calico":
        calico_url = "https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml"
        resp = http.get(calico_url)
        if resp.status_code != 200:
            fail("Failed fetching Calico CNI manifest: HTTP " + str(resp.status_code))
        k8s_client.apply(resp.get_text(), force=True)
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
    """Deploys an application stack to verify cluster scheduling and pod networking natively."""
    printf("\nDeploying smoke-test workload to verify cluster functionality...\n")
    manifest = """
apiVersion: v1
kind: Namespace
metadata:
  name: platform-smoke-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-api
  namespace: platform-smoke-test
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-api
  template:
    metadata:
      labels:
        app: demo-api
    spec:
      containers:
        - name: web
          image: nginx:alpine
          ports:
            - containerPort: 80
"""
    k8s_client.apply(manifest)
    printf("  [SUCCESS] Smoke-test workload applied natively via k8s module.\n")

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

def main():
    opts = args.parse()

    driver = opts.driver.lower()
    cp_node = opts.cp
    workers = [w.strip() for w in opts.workers if w.strip()]
    pod_cidr = opts.pod_cidr
    cni = opts.cni.lower()
    kubeconfig_out = opts.kubeconfig

    all_nodes = [cp_node] + workers

    printf("\n=== Starkite Upstream Kubeadm Bootstrap ===\n")
    printf("Driver         : %s\n", driver)
    printf("Control Plane  : %s\n", cp_node)
    printf("Workers        : %s\n", ", ".join(workers))
    printf("CNI Network    : %s (CIDR: %s)\n", cni, pod_cidr)
    printf("Kubeconfig Out : %s\n\n", kubeconfig_out)

    # 1. Pre-flight checks: binary installation & bidirectional network mesh
    printf("[Pre-flight] Verifying node prerequisites and network mesh...\n")
    for node in all_nodes:
        check_node_ready_for_bootstrap(driver, node)
    verify_cluster_mesh(driver, cp_node, workers)
    printf("  [SUCCESS] All nodes prepared and network mesh verified.\n\n")

    # 2. Initialize Control Plane
    init_control_plane(driver, cp_node, pod_cidr)

    # 3. Retrieve Kubeconfig
    fetch_and_save_kubeconfig(driver, cp_node, kubeconfig_out)

    # 4. Extract join token & join worker nodes concurrently
    join_cmd = get_join_command(driver, cp_node)
    printf("  Joining %d worker nodes concurrently...\n", len(workers))
    concur.map(workers, lambda w: join_worker_node(driver, w, join_cmd))

    # Initialize native Starkite Kubernetes client
    k8s_client = get_k8s_client(kubeconfig_out)

    # 5. Install CNI Network Plugin via native k8s module
    install_cni(k8s_client, cni)

    # 6. Assert Cluster Readiness via native k8s module
    assert_cluster_readiness(k8s_client, len(all_nodes))

    # 7. Deploy Smoke Test via native k8s module
    deploy_smoke_test_workload(k8s_client)

    # Print status output using native k8s module
    printf("\n=== Cluster Bootstrap Complete ===\n\n")
    print_cluster_nodes(k8s_client)

    printf("\nTo interact with your new cluster locally:\n")
    printf("  export KUBECONFIG=$(pwd)/kubeconfig\n")
    printf("  kubectl get pods -A\n\n")
