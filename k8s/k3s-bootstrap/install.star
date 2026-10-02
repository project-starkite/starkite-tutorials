# install.star - Kubernetes (k3s) control plane and worker join orchestration
load("./config.star", "config")

def install_k8s():
    """Install control plane on k8s-controller and join worker nodes."""
    print("=" * 65)
    print("Phase 2: Kubernetes Installation (k3s)")
    print("=" * 65)

    if not fs.path(config.key_path).exists():
        printf("Error: Temporary key %s not found.\n", config.key_path)
        print("Run key setup first:")
        print("  kite run ./bootstrap.star --var action=setup-keys")
        return

    # 1. Initialize Control Plane Node (k8s-controller)
    print("\n[1/3] Checking / Installing k3s control plane on %s..." % config.control_plane)
    server_client = ssh.config(
        hosts          = [config.control_plane],
        auth           = config.auth_config,
        jump           = config.jump_config,
        sudo           = True,
        host_key_check = False,
    )

    check_res = server_client.exec("systemctl is-active k3s 2>/dev/null || true")
    if check_res[0].stdout.strip() == "active":
        printf("  [%s] Control plane (k3s) is already active (skipping re-install).\n", config.control_plane)
    else:
        server_cmd = (
            "curl -sfL https://get.k3s.io | " +
            "INSTALL_K3S_EXEC='server --write-kubeconfig-mode 644 --node-name " + config.control_plane + "' sh -"
        )
        res = server_client.exec(server_cmd)
        if not res[0].ok:
            printf("Control plane installation failed on %s: %s\n", config.control_plane, res[0].stderr)
            return
        printf("Control plane installed on %s (exit code %d).\n", config.control_plane, res[0].code)

    # 2. Retrieve Cluster Join Token from Control Plane
    print("\n[2/3] Retrieving node join token from %s..." % config.control_plane)
    token_res = server_client.exec("cat /var/lib/rancher/k3s/server/node-token")
    k3s_token = token_res[0].stdout.strip()
    if not k3s_token:
        print("Error: Could not retrieve k3s node token from control plane.")
        return
    print("Cluster token retrieved.")

    # 3. Join Worker Nodes
    print("\n[3/3] Joining worker nodes (%s)..." % ", ".join(config.workers))
    worker_client = ssh.config(
        hosts          = config.workers,
        auth           = config.auth_config,
        jump           = config.jump_config,
        sudo           = True,
        exec_policy    = "linear",
        host_key_check = False,
    )

    check_results = worker_client.exec("systemctl is-active k3s-agent 2>/dev/null || true")
    to_join = []
    for r in check_results:
        if r.stdout.strip() == "active":
            printf("  [%s] Already active (skipped)\n", r.host)
        else:
            to_join.append(r.host)

    if len(to_join) > 0:
        join_client = ssh.config(
            hosts          = to_join,
            auth           = config.auth_config,
            jump           = config.jump_config,
            sudo           = True,
            exec_policy    = "linear",
            host_key_check = False,
        )
        join_cmd = (
            "curl -sfL https://get.k3s.io | " +
            "K3S_URL=https://" + config.control_plane + ":6443 " +
            "K3S_TOKEN=" + k3s_token + " sh -"
        )
        join_results = join_client.exec(join_cmd)
        for r in join_results:
            status = "OK" if r.ok else "FAILED"
            printf("  [%s] %s (exit code %d)\n", r.host, status, r.code)
            if not r.ok:
                printf("    error: %s\n", r.stderr.strip())

    # 4. Verify Cluster Readiness
    print("\nCluster Node Verification:")
    status_results = server_client.exec("kubectl get nodes -o wide")
    for r in status_results:
        print(r.stdout)
