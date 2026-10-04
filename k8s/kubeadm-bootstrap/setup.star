#!/usr/bin/env kite --allow-all
# setup.star - Configurable Local Node Provisioner & Kubeadm Installer
#
# Automates the infrastructure layer for Kubernetes cluster bootstrapping:
# 1. Configurable start of machines: Supports either Lima VMs (macOS) or Podman containers
# 2. Automated download & installation of upstream kubeadm, kubelet, kubectl, and containerd
# 3. Kernel and OS preparation: Disables swap, loads overlay/br_netfilter, and configures systemd cgroups
#
# Usage:
#   # 1. Start Lima VMs and install kubeadm (Default for macOS):
#   kite run ./setup.star --driver lima
#
#   # 2. Start Podman containers and install kubeadm:
#   kite run ./setup.star --driver podman
#
#   # 3. Check cluster node machine status:
#   kite run ./setup.star --action status --driver lima
#
#   # 4. Install kubeadm on existing running machines without creating new ones:
#   kite run ./setup.star --action install-kubeadm --driver lima
#
#   # 5. Stop running machines:
#   kite run ./setup.star --action stop --driver lima
#
#   # 6. Teardown and delete machines:
#   kite run ./setup.star --action destroy --driver lima

load("concur", "concur")

# ---------------------------------------------------------------------------
# CLI Argument Schema
# ---------------------------------------------------------------------------
args.string(
    "driver",
    shorthand = "d",
    default = "lima",
    choices = ["lima", "podman"],
    help = "Virtualization driver: lima (macOS) or podman",
)

args.string(
    "action",
    shorthand = "a",
    default = "start",
    choices = ["start", "install-kubeadm", "status", "stop", "destroy"],
    help = "Lifecycle action: start, install-kubeadm, status, stop, destroy",
)

args.string(
    "version",
    default = "1.31",
    help = "Kubernetes upstream package version (e.g. 1.31)",
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

args.int(
    "cpus",
    default = 2,
    min = 1,
    help = "vCPUs per node machine",
)

args.int(
    "memory",
    shorthand = "m",
    default = 2,
    min = 1,
    help = "RAM memory in GB per machine",
)

args.int(
    "disk",
    default = 20,
    min = 5,
    help = "Disk size in GB per machine (Lima only)",
)

def run_local(cmd):
    """Executes a command on the local host shell."""
    sh = os.sh()
    res = sh.try_exec(cmd)
    return res

def exec_node(driver, node, cmd):
    """Executes a command inside the target VM or container."""
    if driver == "lima":
        escaped_cmd = cmd.replace("'", "'\"'\"'")
        lima_cmd = "limactl shell %s sudo bash -c '%s'" % (node, escaped_cmd)
        return run_local(lima_cmd)
    elif driver == "podman":
        escaped_cmd = cmd.replace("'", "'\"'\"'")
        podman_cmd = "podman exec -i %s bash -c '%s'" % (node, escaped_cmd)
        return run_local(podman_cmd)
    else:
        fail("Unsupported driver: " + driver)

def check_driver_prerequisites(driver):
    """Verifies that the required local virtualization CLI is available."""
    if driver == "lima":
        res = run_local("which limactl")
        if not res.ok:
            fail("limactl not found in PATH. Install with: brew install lima")
    elif driver == "podman":
        res = run_local("which podman")
        if not res.ok:
            fail("podman not found in PATH. Install with: brew install podman")
    else:
        fail("Driver must be 'lima' or 'podman', got: " + driver)

def start_machine(driver, node, cpus, memory_gb, disk_gb):
    """Ensures a machine instance exists and is running."""
    printf("  Checking instance %s on %s...\n", node, driver)

    if driver == "lima":
        # Check existing Lima instances
        list_res = run_local("limactl list -q")
        existing_vms = [v.strip() for v in list_res.stdout.split("\n") if v.strip()]
        
        if node in existing_vms:
            status_res = run_local("limactl list --format '{{.Name}}: {{.Status}}'")
            if node + ": Running" in status_res.stdout:
                printf("  [%s] Lima VM is already Running.\n", node)
                return True
            printf("  [%s] Starting existing stopped Lima VM...\n", node)
            start_res = run_local("limactl start --tty=false " + node)
            return start_res.ok

        printf("  [%s] Creating and starting Ubuntu Lima VM (cpus: %d, memory: %dG)...\n", node, cpus, memory_gb)
        create_cmd = (
            "limactl start --name=%s --tty=false --cpus=%d --memory=%d --disk=%d template://ubuntu"
            % (node, cpus, memory_gb, disk_gb)
        )
        res = run_local(create_cmd)
        if not res.ok:
            printf("  Error creating Lima VM %s: %s\n", node, res.stderr)
            return False
        return True

    elif driver == "podman":
        # Ensure podman bridge network exists
        run_local("podman network create k8s-cluster 2>/dev/null || true")

        # Check existing container
        ps_res = run_local("podman ps -a --format '{{.Names}}'")
        containers = [c.strip() for c in ps_res.stdout.split("\n") if c.strip()]

        if node in containers:
            status_res = run_local("podman ps --format '{{.Names}}'")
            if node in status_res.stdout:
                printf("  [%s] Podman container is already Running.\n", node)
                return True
            printf("  [%s] Starting existing stopped Podman container...\n", node)
            return run_local("podman start " + node).ok

        printf("  [%s] Creating and starting Ubuntu systemd container on k8s-cluster network...\n", node)
        run_cmd = (
            "podman run -d --name %s --hostname %s --net k8s-cluster --privileged " +
            "-v /lib/modules:/lib/modules:ro ubuntu:24.04 /sbin/init"
        ) % (node, node)
        res = run_local(run_cmd)
        if not res.ok:
            printf("  Error starting container %s: %s\n", node, res.stderr)
            return False
        return True

def install_kubeadm_node(driver, node, k8s_version):
    """Downloads and installs containerd, kubelet, kubeadm, and kubectl on a node."""
    printf("  [%s] Step 1/5: Disabling swap and loading kernel modules (overlay, br_netfilter)...\n", node)
    kmod_script = """
    swapoff -a
    sed -i '/swap/d' /etc/fstab || true
    cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    modprobe overlay || true
    modprobe br_netfilter || true
    cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sysctl --system >/dev/null 2>&1 || true
    """
    exec_node(driver, node, kmod_script)

    printf("  [%s] Step 2/5: Installing and configuring containerd runtime...\n", node)
    containerd_script = """
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq apt-transport-https ca-certificates curl gpg containerd >/dev/null
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    systemctl restart containerd
    systemctl enable containerd >/dev/null 2>&1
    """
    res = exec_node(driver, node, containerd_script)
    if not res.ok:
        printf("  [%s] Failed to configure containerd: %s\n", node, res.stderr)
        return False

    printf("  [%s] Step 3/5: Configuring Kubernetes apt repository (pkgs.k8s.io v%s)...\n", node, k8s_version)
    repo_script = """
    export DEBIAN_FRONTEND=noninteractive
    mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v%s/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v%s/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq >/dev/null
    """ % (k8s_version, k8s_version)
    exec_node(driver, node, repo_script)

    printf("  [%s] Step 4/5: Installing kubeadm, kubelet, and kubectl...\n", node)
    pkg_script = """
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq kubelet kubeadm kubectl >/dev/null
    apt-mark hold kubelet kubeadm kubectl >/dev/null
    systemctl enable kubelet >/dev/null 2>&1
    """
    res = exec_node(driver, node, pkg_script)
    if not res.ok:
        printf("  [%s] Failed installing Kubernetes packages: %s\n", node, res.stderr)
        return False

    printf("  [%s] Step 5/5: Verifying installation...\n", node)
    ver_res = exec_node(driver, node, "kubeadm version -o short && containerd --version")
    if ver_res.ok:
        versions = ver_res.stdout.strip().replace("\n", ", ")
        printf("  [%s SUCCESS] Installed: %s\n", node, versions)
        return True
    else:
        printf("  [%s WARNING] Verification output: %s\n", node, ver_res.stderr)
        return False

def get_node_ip(driver, node):
    """Retrieves the primary IP address of a node."""
    if driver == "lima":
        res = run_local("limactl shell %s hostname -I" % node)
        if res.ok:
            return res.stdout.strip().split(" ")[0]
    elif driver == "podman":
        res = run_local("podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' " + node)
        if res.ok:
            return res.stdout.strip()
    return "unknown"

def main():
    opts = args.parse()

    driver = opts.driver.lower()
    action = opts.action.lower()
    k8s_ver = opts.version
    cp_node = opts.cp
    workers = [w.strip() for w in opts.workers if w.strip()]
    cpus = opts.cpus
    memory_gb = opts.memory
    disk_gb = opts.disk

    all_nodes = [cp_node] + workers

    check_driver_prerequisites(driver)

    printf("\n=== Starkite Kubeadm Node Setup ===\n")
    printf("Driver         : %s\n", driver)
    printf("Action         : %s\n", action)
    printf("K8s Version    : %s\n", k8s_ver)
    printf("Control Plane  : %s\n", cp_node)
    printf("Workers        : %s\n", ", ".join(workers))
    printf("Hardware Alloc : %d vCPUs, %d GB RAM per node\n\n", cpus, memory_gb)

    if action == "start":
        print("[Phase 1/2] Starting machine instances...")
        for node in all_nodes:
            ok = start_machine(driver, node, cpus, memory_gb, disk_gb)
            if not ok:
                fail("Failed starting machine: " + node)
        printf("\nAll %d machines are running.\n\n", len(all_nodes))

        print("[Phase 2/2] Downloading & installing containerd and kubeadm on all nodes...")
        # Concurrently install packages on all nodes
        results = concur.map(all_nodes, lambda n: install_kubeadm_node(driver, n, k8s_ver))
        
        printf("\n--- Setup Complete Summary ---\n")
        for node in all_nodes:
            ip = get_node_ip(driver, node)
            role = "Control Plane" if node == cp_node else "Worker Node"
            printf("  • %-14s (%s)  IP: %-15s  Status: Ready for kubeadm\n", node, role, ip)

        printf("\nNext step: Run cluster bootstrap:\n")
        printf("  kite run ./bootstrap.star --driver %s --cp %s\n\n", driver, cp_node)

    elif action == "install-kubeadm":
        print("Installing kubeadm on running instances...")
        concur.map(all_nodes, lambda n: install_kubeadm_node(driver, n, k8s_ver))
        print("\nKubeadm installation pass complete.")

    elif action == "status":
        print("Querying machine and kubeadm status:")
        for node in all_nodes:
            ip = get_node_ip(driver, node)
            ver = exec_node(driver, node, "kubeadm version -o short 2>/dev/null || echo 'not installed'")
            printf("  • %-14s  IP: %-15s  Kubeadm: %s\n", node, ip, ver.stdout.strip())

    elif action == "stop":
        print("Stopping machines...")
        for node in all_nodes:
            printf("  Stopping %s...\n", node)
            if driver == "lima":
                run_local("limactl stop " + node)
            elif driver == "podman":
                run_local("podman stop " + node)
        print("All machines stopped.")

    elif action == "destroy":
        print("Destroying and cleaning up machines...")
        for node in all_nodes:
            printf("  Destroying %s...\n", node)
            if driver == "lima":
                run_local("limactl stop -f %s 2>/dev/null || true" % node)
                run_local("limactl delete -f %s 2>/dev/null || true" % node)
            elif driver == "podman":
                run_local("podman rm -f %s 2>/dev/null || true" % node)
        if driver == "podman":
            run_local("podman network rm k8s-cluster 2>/dev/null || true")
        print("Teardown complete.")

    else:
        fail("Unknown action: " + action + ". Supported actions: start, install-kubeadm, status, stop, destroy")
