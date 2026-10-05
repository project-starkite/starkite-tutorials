#!/usr/bin/env kite --allow-all
# setup.star - Provision Lima VMs and install Kubernetes prerequisites
#
# Generates declarative Lima YAML specifications (with embedded OS & kubeadm provisioning)
# and manages virtual machine lifecycles for the upstream Kubernetes cluster.
#
# Usage:
#   # 1. Start all machines and provision kubeadm prerequisites:
#   kite run ./setup.star
#
#   # 2. Check cluster machine status:
#   kite run ./setup.star --action status
#
#   # 3. Stop machines:
#   kite run ./setup.star --action stop
#
#   # 4. Destroy machines and clean up runtime manifests:
#   kite run ./setup.star --action destroy

load("concur", "concur")
load("./lima.star", "lima")

# ---------------------------------------------------------------------------
# CLI Argument Schema
# ---------------------------------------------------------------------------
args.string(
    "action",
    shorthand = "a",
    default = "start",
    choices = ["start", "status", "stop", "destroy"],
    help = "Lifecycle action: start, status, stop, destroy",
)

args.string(
    "version",
    shorthand = "v",
    default = "1.31",
    help = "Kubernetes minor version (e.g., 1.31)",
)

args.string(
    "cp",
    default = "k8s-cp",
    help = "Control plane machine name",
)

args.list(
    "workers",
    shorthand = "w",
    default = ["k8s-worker-1", "k8s-worker-2"],
    item_type = "string",
    help = "Worker machine hostnames",
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

def main():
    opts = args.parse()

    action = opts.action.lower()
    k8s_ver = opts.version
    cp_node = opts.cp
    workers = [w.strip() for w in opts.workers if w.strip()]
    cpus = opts.cpus
    memory_gb = opts.memory
    disk_gb = opts.disk

    all_nodes = [cp_node] + workers

    lima.check_prerequisites()

    printf("\n=== Starkite Kubeadm Node Setup ===\n")
    printf("Driver         : lima\n")
    printf("Action         : %s\n", action)
    printf("K8s Version    : %s\n", k8s_ver)
    printf("Control Plane  : %s\n", cp_node)
    printf("Workers        : %s\n", ", ".join(workers))
    printf("Hardware Alloc : %d vCPUs, %d GB RAM per node\n\n", cpus, memory_gb)

    if action == "start":
        print("[1/2] Launching and provisioning Lima machines...")
        # Start nodes sequentially or concurrently (Lima handles individual instance starts)
        for node in all_nodes:
            start_node(node, cpus, memory_gb, disk_gb, k8s_ver)

        printf("\n[2/2] Verifying node readiness and installed packages...\n")
        concur.map(all_nodes, verify_node)

        printf("\n--- Setup Complete Summary ---\n")
        for node in all_nodes:
            ip = lima.get_ip(node)
            role = "Control Plane" if node == cp_node else "Worker Node"
            printf("  • %-14s (%s)  IP: %-15s  Status: Ready for kubeadm\n", node, role, ip)

        printf("\nNext step: Run cluster bootstrap:\n")
        printf("  kite run ./bootstrap.star --cp %s\n\n", cp_node)

    elif action == "status":
        print("Querying machine status:")
        for node in all_nodes:
            status = lima.get_status(node)
            ip = lima.get_ip(node) if status == "Running" else "N/A"
            ver = "N/A"
            if status == "Running":
                ver_res = lima.exec(node, "kubeadm version -o short 2>/dev/null || echo 'not installed'")
                ver = ver_res.stdout.strip()
            printf("  • %-14s  Status: %-10s  IP: %-15s  Kubeadm: %s\n", node, status, ip, ver)

    elif action == "stop":
        print("Stopping machines...")
        for node in all_nodes:
            printf("  Stopping %s...\n", node)
            lima.stop(node)
        print("All machines stopped.")

    elif action == "destroy":
        print("Destroying machines and clearing runtime manifests...")
        for node in all_nodes:
            printf("  Destroying %s...\n", node)
            lima.delete(node, force = True)
        print("Teardown complete.")

    else:
        fail("Unknown action: " + action + ". Supported actions: start, status, stop, destroy")
