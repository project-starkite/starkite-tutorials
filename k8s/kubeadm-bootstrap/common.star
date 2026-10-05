# common.star - Shared helper functions for kubeadm bootstrap scripts

load("k8s", "k8s")
load("./lima.star", "lima")

def verify_cluster_mesh(cp_node, worker_nodes):
    """Verifies bidirectional network connectivity across all cluster nodes."""
    cp_ip = lima.get_ip(cp_node)
    if cp_ip == "unknown" or not cp_ip:
        fail("Unable to resolve control plane IP for network verification: " + cp_node)

    for worker in worker_nodes:
        # Probe control plane from worker
        ping_res = lima.exec(worker, "ping -c 2 -W 3 " + cp_ip)
        if not ping_res.ok:
            fail("Network mesh check failed: %s cannot reach control plane %s (%s)" % (worker, cp_node, cp_ip))

        # Probe worker from control plane
        worker_ip = lima.get_ip(worker)
        if worker_ip != "unknown" and worker_ip:
            cp_probe = lima.exec(cp_node, "ping -c 2 -W 3 " + worker_ip)
            if not cp_probe.ok:
                fail("Network mesh check failed: %s cannot reach worker %s (%s)" % (cp_node, worker, worker_ip))

    return True

def get_k8s_client(kubeconfig_path = None):
    """Returns a native Starkite Kubernetes client configured with the given kubeconfig."""
    if not kubeconfig_path:
        kubeconfig_path = lima.get_kubeconfig_path()
    return k8s.config(kubeconfig = kubeconfig_path)
