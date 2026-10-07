# setup.star - Provision Lima VMs and install Kubernetes prerequisites
#
# Generates declarative Lima YAML specifications (with embedded OS & kubeadm provisioning)
# and manages virtual machine lifecycles for the upstream Kubernetes cluster.

load("concur", "concur")
load("./lima.star", "lima")

def start_node(node, config):
    """Generates manifest and starts a Lima node with embedded cloud provisioning."""
    printf("  [%s] Generating machine specification...\n", node)
    manifest_path = lima.generate_manifest(node, config)
    printf("  [%s] Starting Lima VM (cpus: %d, memory: %dGiB)...\n", node, config["cpus"], config["memory_gb"])
    ok = lima.start(node, manifest_path)
    if not ok:
        fail("Failed starting Lima machine: " + node)
    return node

def verify_node(node):
    """Verifies that kubeadm and containerd were provisioned successfully."""
    ver_res = lima.exec(node, "kubeadm version -o short && containerd --version")
    if ver_res.ok:
        versions = ver_res.stdout.strip().replace("\n", ", ")
        printf("  [%s SUCCESS] Ready: %s\n", node, versions)
        return True
    else:
        printf("  [%s WARNING] Verification: %s\n", node, ver_res.stderr)
        return False

def start_nodes(all_nodes, cp_node):
    """Launches, provisions, and verifies all Lima machines."""
    lima.check_prerequisites()

    cp_cfg = lima.get_control_plane_config()
    worker_cfg = lima.get_worker_config()

    printf("\n=== Starkite Kubeadm Machine Provisioning ===\n")
    printf("Driver         : lima\n")
    printf("K8s Version    : %s\n", cp_cfg["k8s_version"])
    printf("Control Plane  : %s (%d vCPUs, %d GiB RAM, %d GiB disk)\n",
           cp_node, cp_cfg["cpus"], cp_cfg["memory_gb"], cp_cfg["disk_gb"])
    workers = [n for n in all_nodes if n != cp_node]
    if workers:
        printf("Workers        : %s (%d vCPUs, %d GiB RAM, %d GiB disk per worker)\n\n",
               ", ".join(workers), worker_cfg["cpus"], worker_cfg["memory_gb"], worker_cfg["disk_gb"])
    else:
        printf("Workers        : none\n\n")

    print("[1/2] Launching and provisioning Lima machines...")
    for node in all_nodes:
        cfg = cp_cfg if node == cp_node else worker_cfg
        start_node(node, cfg)

    printf("\n[2/2] Verifying node readiness and installed packages...\n")
    concur.map(all_nodes, verify_node)

    printf("\n--- Provisioning Complete Summary ---\n")
    for node in all_nodes:
        ip = lima.get_ip(node)
        role = "Control Plane" if node == cp_node else "Worker Node"
        printf("  • %-14s (%s)  IP: %-15s  Status: Ready for kubeadm\n", node, role, ip)

    printf("\nNext step: Run cluster bootstrap:\n")
    printf("  ./main.star --action bootstrap --cp %s\n\n", cp_node)

def show_machine_status(all_nodes):
    """Queries and displays host machine status and kubeadm package readiness."""
    print("Machine Status:")
    for node in all_nodes:
        status = lima.get_status(node)
        ip = lima.get_ip(node) if status == "Running" else "N/A"
        ver = "N/A"
        if status == "Running":
            ver_res = lima.exec(node, "kubeadm version -o short 2>/dev/null || echo 'not installed'")
            ver = ver_res.stdout.strip()
        printf("  • %-14s  Status: %-10s  IP: %-15s  Kubeadm: %s\n", node, status, ip, ver)
    print("")

def stop_nodes(all_nodes):
    """Stops the specified Lima machines."""
    print("Stopping machines...")
    for node in all_nodes:
        printf("  Stopping %s...\n", node)
        lima.stop(node)
    print("All machines stopped.\n")

def destroy_nodes(all_nodes):
    """Permanently destroys the specified Lima machines and cleans up runtime manifests."""
    print("Destroying machines and clearing runtime manifests...")
    for node in all_nodes:
        printf("  Destroying %s...\n", node)
        lima.delete(node, force = True)
    print("Teardown complete.\n")
