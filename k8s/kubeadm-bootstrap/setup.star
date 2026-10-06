# setup.star - Provision Lima VMs and install Kubernetes prerequisites
#
# Generates declarative Lima YAML specifications (with embedded OS & kubeadm provisioning)
# and manages virtual machine lifecycles for the upstream Kubernetes cluster.

load("concur", "concur")
load("./lima.star", "lima")

def start_node(node, cpus, memory_gb, disk_gb, k8s_version):
    """Generates manifest and starts a Lima node with embedded cloud provisioning."""
    printf("  [%s] Generating machine specification...\n", node)
    manifest_path = lima.generate_manifest(node, cpus, memory_gb, disk_gb, k8s_version)
    printf("  [%s] Starting Lima VM (cpus: %d, memory: %dGiB)...\n", node, cpus, memory_gb)
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

def start_nodes(all_nodes, cp_node, cpus, memory_gb, disk_gb, k8s_ver):
    """Launches, provisions, and verifies all Lima machines."""
    lima.check_prerequisites()

    printf("\n=== Starkite Kubeadm Machine Provisioning ===\n")
    printf("Driver         : lima\n")
    printf("K8s Version    : %s\n", k8s_ver)
    printf("Control Plane  : %s\n", cp_node)
    printf("Target Nodes   : %s\n", ", ".join(all_nodes))
    printf("Hardware Alloc : %d vCPUs, %d GB RAM per node\n\n", cpus, memory_gb)

    print("[1/2] Launching and provisioning Lima machines...")
    for node in all_nodes:
        start_node(node, cpus, memory_gb, disk_gb, k8s_ver)

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
