# common.star - Shared helper functions for kubeadm bootstrap scripts

def run_local(cmd):
    """Executes a command on the local host shell."""
    sh = os.sh()
    return sh.try_exec(cmd)

def exec_node(driver, node, cmd):
    """Executes a command inside the target VM or container."""
    escaped_cmd = cmd.replace("'", "'\"'\"'")
    if driver == "lima":
        lima_cmd = "limactl shell %s sudo bash -c '%s'" % (node, escaped_cmd)
        return run_local(lima_cmd)
    elif driver == "podman":
        podman_cmd = "podman exec -i %s bash -c '%s'" % (node, escaped_cmd)
        return run_local(podman_cmd)
    else:
        fail("Unsupported driver: " + driver)

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
