# keys.star - SSH host key discovery, keypair generation, and key distribution
load("./config.star", "config")

def setup_keys():
    """Discover host keys, generate temporary Ed25519 keypair, and distribute to all nodes."""
    print("=" * 65)
    print("Phase 1: Temporary SSH Key Generation & Distribution")
    print("=" * 65)

    # 1. Scan and register remote host keys through bastion into known_hosts
    print("[1/3] Scanning remote host keys through bastion...")
    scan_res = ssh.try_scan_host_keys(
        hosts = config.all_nodes,
        jump  = config.jump_config,
        save  = True,
    )
    if not scan_res.ok:
        print("Warning: Host key scan failed:", scan_res.error)
        print("Continuing with host_key_check=False fallback if needed...")
    else:
        print("Host keys registered in known_hosts.")

    # 2. Generate dedicated temporary Ed25519 keypair
    print("\n[2/3] Generating temporary Ed25519 keypair...")
    kp = ssh.keygen(
        type      = "ed25519",
        comment   = "k8s-cluster-temp-bootstrap",
        path      = config.key_path,
        overwrite = True,
    )
    printf("  Private key: %s\n", kp.path)
    printf("  Public key:  %s\n", kp.pub_path)
    printf("  Fingerprint: %s\n", kp.fingerprint)

    # 3. Distribute public key to all nodes through bastion
    print("\n[3/3] Distributing public key to all nodes via bastion...")
    auth_config = config.auth_config
    cluster_pass = var_str("password", "")
    
    if cluster_pass != "":
        auth_config["password"] = cluster_pass
    else:
        auth_config["prompt"] = True

    bootstrap_client = ssh.config(
        hosts          = config.all_nodes,
        auth           = auth_config,
        jump           = config.jump_config,
        host_key_check = False,
        timeout        = "5s",
        max_retries    = 1,
    )

    # check_first=True probes RFC 4252 authorization first; skips already authorized nodes
    res = bootstrap_client.try_copy_id(
        key         = kp.public_key,
        sudo        = True,
        check_first = True,
    )
    if not res.ok:
        printf("Key distribution error: %s\n", res.error)
        return
    for r in res.value:
        printf("  [%s] %s\n", r.host, r.stdout.strip())

    print("\nTemporary key distribution complete.")
    print("Next step:")
    print("  kite run ./bootstrap.star --var action=install")
