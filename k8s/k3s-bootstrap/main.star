#!/usr/bin/env kite --allow-all
# main.star - Bootstrap Kubernetes (k3s) using a bastion node
#
# Usage:
#   # Step 1: Optional generate and distribute host keys
#   kite run ./main.star --var action=setup-keys
#
#   # Step 2: Install Kubernetes (control plane + workers)
#   kite run ./bootstrap.star --var action=install --allow-net
#
# Parameters:
#   --var action=setup-keys | install
#   --var key_path=~/.ssh/id_k8s_cluster_temp (optional, defaults to temp_dir)

load("./install.star", "install")
load("./keys.star", "keys")

def main():
    action = var_str("action", var_str("step", "")).lower()

    if action == "setup-keys":
        keys.setup_keys()
    elif action == "install":
        install.install_k8s()
    else:
        print("Usage:")
        print("  kite run ./bootstrap.star --var action=setup-keys --allow-net")
        print("  kite run ./bootstrap.star --var action=install --allow-net")
        print("")
        print("Options:")
        print("  --var key_path=<path>       Custom path for temporary SSH key")
