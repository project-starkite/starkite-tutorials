# lima.star - Encapsulation of Lima VM operations for Starkite
#
# Provides high-level abstractions for managing Lima VMs:
# - Machine specification generation with embedded OS and containerd/kubeadm provisioning
# - Instance query and JSON inspection via `limactl list --format json`
# - Instance lifecycle management: start, stop, delete, and shell execution
# - Isolates all runtime artifacts into ~/.starkite/tutorials/k8s/ to avoid repository leakage

load("base64", "base64")
load("json", "json")
load("template", "template")
load("yaml", "yaml")

def _sh_exec(cmd):
    """Executes a command on the local host shell."""
    sh = os.sh()
    return sh.try_exec(cmd)

def check_prerequisites():
    """Verifies that limactl is available in PATH."""
    res = _sh_exec("which limactl")
    if not res.ok:
        fail("limactl not found in PATH. Install with: brew install lima")

def get_data_dir():
    """Returns the root directory for runtime cluster files (~/.starkite/tutorials/k8s)."""
    return os.home() + "/.starkite/tutorials/k8s"

def get_manifests_dir():
    """Returns the directory for generated Lima YAML specifications."""
    return get_data_dir() + "/manifests"

def get_kubeconfig_path():
    """Returns the default cluster kubeconfig file path."""
    return get_data_dir() + "/kubeconfig"

def ensure_dirs():
    """Ensures that runtime directories exist."""
    _sh_exec("mkdir -p " + get_manifests_dir())

def generate_manifest(node, cpus = 2, memory_gb = 2, disk_gb = 20, k8s_version = "1.31", template_path = "./cloud-init-template.yaml"):
    """Generates a Lima YAML instance definition file using externalized cloud-init-template.yaml."""
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
    res = _sh_exec("limactl list --format json " + node)
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
    res = _sh_exec("limactl shell %s hostname -I" % node)
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
        res = _sh_exec("limactl start --tty=false " + node)
        return res.ok

    # If instance does not exist, start from manifest
    if not manifest_path:
        fail("Cannot create new Lima instance %s: manifest_path is required" % node)
    res = _sh_exec("limactl start --name=%s --tty=false %s" % (node, manifest_path))
    return res.ok

def stop(node):
    """Stops a running Lima VM."""
    res = _sh_exec("limactl stop " + node)
    return res.ok

def delete(node, force = True):
    """Permanently stops and deletes a Lima VM and its local manifest."""
    flag = "-f" if force else ""
    _sh_exec("limactl stop %s %s 2>/dev/null || true" % (flag, node))
    res = _sh_exec("limactl delete %s %s 2>/dev/null || true" % (flag, node))
    manifest_path = "%s/lima-%s.yaml" % (get_manifests_dir(), node)
    _sh_exec("rm -f " + manifest_path)
    return res.ok

def exec(node, cmd, sudo = True):
    """Executes a command inside the Lima VM via limactl shell."""
    escaped_cmd = cmd.replace("'", "'\"'\"'")
    if sudo:
        full_cmd = "limactl shell %s sudo bash -c '%s'" % (node, escaped_cmd)
    else:
        full_cmd = "limactl shell %s bash -c '%s'" % (node, escaped_cmd)
    return _sh_exec(full_cmd)
