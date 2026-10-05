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

def generate_manifest(node, cpus = 2, memory_gb = 2, disk_gb = 20, k8s_version = "1.31"):
    """Generates a Lima YAML instance definition file using Starkite templating and declarative data provisions."""
    ensure_dirs()
    manifest_path = "%s/lima-%s.yaml" % (get_manifests_dir(), node)

    # Starkite-centric template for the embedded provisioning script
    script_tmpl = template.text("""#!/bin/bash
set -eux -o pipefail

# 1. OS kernel runtime activation
swapoff -a
sed -i '/swap/d' /etc/fstab
modprobe overlay
modprobe br_netfilter
sysctl --system

# 2. Containerd runtime
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# 3. Kubernetes packages
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v{{.version}}/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v{{.version}}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet
""")

    provision_script = script_tmpl.render({"version": k8s_version})

    # Declarative Lima machine specification using Starkite data structures
    manifest_data = {
        "base": ["template:ubuntu-24.04"],
        "cpus": cpus,
        "memory": "%dGiB" % memory_gb,
        "disk": "%dGiB" % disk_gb,
        "networks": [{"lima": "user-v2"}],
        "containerd": {
            "system": False,
            "user": False,
        },
        "provision": [
            {
                "mode": "data",
                "path": "/etc/modules-load.d/k8s.conf",
                "content": "overlay\nbr_netfilter\n",
                "owner": "root:root",
                "permissions": "0644",
            },
            {
                "mode": "data",
                "path": "/etc/sysctl.d/k8s.conf",
                "content": "net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n",
                "owner": "root:root",
                "permissions": "0644",
            },
            {
                "mode": "system",
                "script": provision_script,
            },
        ],
    }

    # Encode with Starkite yaml module and write with Starkite fs module
    encoded_manifest = yaml.encode(manifest_data)
    fs.path(manifest_path).write_text(encoded_manifest)
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
