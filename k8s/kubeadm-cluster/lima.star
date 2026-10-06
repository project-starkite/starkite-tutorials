# lima.star - Encapsulation of Lima VM operations for Starkite
#
# Provides high-level abstractions for managing Lima VMs:
# - Machine specification generation with embedded OS and containerd/kubeadm provisioning
# - Instance query and JSON inspection via `limactl list --format json`
# - Instance lifecycle management: start, stop, delete, and shell execution
# - Host and guest package maintenance: apt updates with native lock timeouts and service restarts
# - Isolates all runtime artifacts into ~/.starkite/tutorials/k8s/ to avoid repository leakage
# - Pure Starkite primitives: native os.which, os.try_exec, and fs.path

load("base64", "base64")
load("json", "json")
load("template", "template")

def check_prerequisites():
    """Verifies that limactl is available in PATH using native os.which."""
    if not os.which("limactl"):
        fail("limactl not found in PATH. Install with: brew install lima")

def resolve_path(p):
    """Expands ~ in paths to user home directory."""
    if p.startswith("~/"):
        return os.home() + p[1:]
    return p

def get_data_dir():
    """Returns the root directory for runtime cluster files (~/.starkite/tutorials/k8s)."""
    return os.home() + "/.starkite/tutorials/k8s"

def get_manifests_dir():
    """Returns the directory for generated Lima YAML specifications."""
    return get_data_dir() + "/manifests"

def get_kubeconfig_path():
    """Returns the portable default cluster kubeconfig file path."""
    return "~/.starkite/tutorials/k8s/kubeconfig"

def ensure_dirs():
    """Ensures that runtime directories exist using native fs.path.mkdir."""
    fs.path(get_manifests_dir()).mkdir(parents = True)

def generate_manifest(node, cpus = 2, memory_gb = 2, disk_gb = 20, k8s_version = "1.31", template_path = "./lima-machine-template.yaml"):
    """Generates a Lima YAML instance definition file using externalized lima-machine-template.yaml."""
    ensure_dirs()
    manifest_path = "%s/lima-%s.yaml" % (get_manifests_dir(), node)

    tmpl = template.file(template_path)
    rendered_yaml = tmpl.render({
        "node": node,
        "cpus": cpus,
        "memory_gb": memory_gb,
        "disk_gb": disk_gb,
        "k8s_version": k8s_version,
    })

    fs.path(manifest_path).write_text(rendered_yaml)
    return manifest_path

def read_file(node, remote_path):
    """Retrieves file contents from a guest node via base64 stream without CLI cat."""
    res = exec(node, "base64 " + remote_path)
    if not res.ok:
        fail("Failed reading %s on %s: %s" % (remote_path, node, res.stderr))
    return str(base64.text(res.stdout.strip()).decode())

def get_instance(node):
    """Retrieves structured JSON inspection metadata for a Lima instance."""
    res = os.try_exec("limactl", ["list", "--format", "json", node])
    if not res.ok:
        return None
    out = res.stdout
    idx = out.find("{")
    if idx < 0:
        return None
    return json.decode(out[idx:])

def get_status(node):
    """Returns the current instance status ('Running', 'Stopped', 'NotFound')."""
    inst = get_instance(node)
    if not inst:
        return "NotFound"
    return inst.get("status", "NotFound")

def get_ip(node):
    """Retrieves the primary routable IPv4 address of a node."""
    res = os.try_exec("limactl", ["shell", node, "hostname", "-I"])
    if res.ok:
        ips = res.stdout.strip().split()
        for ip in ips:
            if ip.startswith("192.168.104.") or ip.startswith("192.168.105."):
                return ip
        if len(ips) > 0:
            return ips[0]
    return "unknown"

def start(node, manifest_path = None):
    """Starts an existing VM or creates and starts a new VM from manifest_path."""
    status = get_status(node)
    if status == "Running":
        return True
    if status == "Stopped":
        res = os.try_exec("limactl", ["start", "--tty=false", node])
        return res.ok

    # If instance does not exist, start from manifest
    if not manifest_path:
        fail("Cannot create new Lima instance %s: manifest_path is required" % node)
    res = os.try_exec("limactl", ["start", "--name=" + node, "--tty=false", manifest_path])
    return res.ok

def stop(node):
    """Stops a running Lima VM."""
    res = os.try_exec("limactl", ["stop", node])
    return res.ok

def delete(node, force = True):
    """Permanently stops and deletes a Lima VM and its local manifest."""
    stop_args = ["stop", "-f", node] if force else ["stop", node]
    os.try_exec("limactl", stop_args)
    del_args = ["delete", "-f", node] if force else ["delete", node]
    res = os.try_exec("limactl", del_args)
    manifest_path = "%s/lima-%s.yaml" % (get_manifests_dir(), node)
    p = fs.path(manifest_path)
    if p.exists():
        p.remove()
    return res.ok

def exec(node, cmd, sudo = True):
    """Executes a command inside the Lima VM via limactl shell."""
    if sudo:
        args = ["shell", node, "sudo", "bash", "-c", cmd]
    else:
        args = ["shell", node, "bash", "-c", cmd]
    return os.try_exec("limactl", args)

def restart_service(node, service):
    """Restarts a systemd service inside the Lima VM."""
    res = exec(node, "systemctl daemon-reload && systemctl restart " + service)
    if not res.ok:
        fail("Failed restarting service %s on %s: %s" % (service, node, res.stderr))
    return res

def upgrade_packages(node, packages, version):
    """Upgrades specific held apt packages inside the Lima VM using native apt lock timeouts."""
    pkgs = " ".join(["%s=%s-*" % (p, version) for p in packages])
    cmd = (
        "export DEBIAN_FRONTEND=noninteractive && " +
        "apt-get update -qq && " +
        "apt-get install -y -qq -o DPkg::Lock::Timeout=60 --allow-change-held-packages %s >/dev/null"
    ) % pkgs
    res = exec(node, cmd)
    if not res.ok:
        fail("Failed upgrading packages [%s] on %s: %s" % (pkgs, node, res.stderr))
    return res
