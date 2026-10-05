# common.star - Shared helper functions for kubeadm bootstrap scripts

load("k8s", "k8s")
load("time", "time")

def run_local(cmd):
    """Executes a command on the local host shell."""
    sh = os.sh()
    return sh.try_exec(cmd)

def exec_node(driver, node, cmd):
    """Executes a command inside the target VM instance."""
    escaped_cmd = cmd.replace("'", "'\"'\"'")
    if driver == "lima":
        lima_cmd = "limactl shell %s sudo bash -c '%s'" % (node, escaped_cmd)
        return run_local(lima_cmd)
    elif driver == "multipass":
        multipass_cmd = "multipass exec %s -- sudo bash -c '%s'" % (node, escaped_cmd)
        return run_local(multipass_cmd)
    else:
        fail("Unsupported driver: " + driver + ". Supported drivers: lima, multipass")

def get_node_ip(driver, node):
    """Retrieves the primary IP address of a node."""
    if driver == "lima":
        res = run_local("limactl shell %s hostname -I" % node)
        if res.ok:
            ips = res.stdout.strip().split()
            for ip in ips:
                if ip.startswith("192.168.104."):
                    return ip
            if len(ips) > 0:
                return ips[0]
    elif driver == "multipass":
        res = run_local("multipass exec %s -- hostname -I" % node)
        if res.ok:
            return res.stdout.strip().split()[0]
    return "unknown"

def wait_for_package_manager(driver, node, max_retries=30):
    """Waits for background OS cloud-init and apt locks to release on a node."""
    for attempt in range(max_retries):
        res = exec_node(driver, node, "fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && echo 'locked' || echo 'free'")
        if "free" in res.stdout:
            return True
        time.sleep("2s")
    fail("Timed out waiting for dpkg lock to release on node " + node)

def verify_cluster_mesh(driver, cp_node, worker_nodes):
    """Verifies bidirectional network connectivity across all cluster nodes."""
    cp_ip = get_node_ip(driver, cp_node)
    if cp_ip == "unknown" or not cp_ip:
        fail("Unable to resolve control plane IP for network verification: " + cp_node)

    for worker in worker_nodes:
        # Probe control plane from worker
        ping_res = exec_node(driver, worker, "ping -c 2 -W 3 " + cp_ip)
        if not ping_res.ok:
            fail("Network mesh check failed: %s cannot reach control plane %s (%s)" % (worker, cp_node, cp_ip))

        # Probe worker from control plane
        worker_ip = get_node_ip(driver, worker)
        if worker_ip != "unknown" and worker_ip:
            cp_probe = exec_node(driver, cp_node, "ping -c 2 -W 3 " + worker_ip)
            if not cp_probe.ok:
                fail("Network mesh check failed: %s cannot reach worker %s (%s)" % (cp_node, worker, worker_ip))

    return True

def get_k8s_client(kubeconfig_path="./kubeconfig"):
    """Returns a native Starkite Kubernetes client configured with the given kubeconfig."""
    return k8s.config(kubeconfig=kubeconfig_path)
