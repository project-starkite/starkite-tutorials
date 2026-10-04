# common.star - Shared helper functions for kubeadm bootstrap scripts

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
            return res.stdout.strip().split(" ")[0]
    elif driver == "multipass":
        res = run_local("multipass exec %s -- hostname -I" % node)
        if res.ok:
            return res.stdout.strip().split(" ")[0]
    return "unknown"
