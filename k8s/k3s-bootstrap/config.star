# config.star - Cluster topology, node definitions, and bastion parameters

bastion_host  = var_str("bastion_host", "jump-host")
bastion_user  = var_str("bastion_user", "ubuntu")
bastion_key   = var_str("bastion_key", "~/.ssh/id_ed25519")


cluster_user  = var_str("cluster_user", "ubuntu")
control_plane = var_str("control_plane", "k8s-controller")
workers = [
      "k8s-worker-1",
      "k8s-worker-2",
      "k8s-worker-3"
]

all_nodes = [control_plane] + workers

# Temporary SSH key path
# temp_key_default = (fs.path(temp_dir()) / "id_k8s_cluster_temp").string
key_path = var_str("key_path", bastion_key)

jump_config = {
    "host":      bastion_host,
    "user":      bastion_user,
    "key":       bastion_key,
    "use_agent": True,
}

auth_config = {
    "user": cluster_user,
    "key":  key_path,
    "use_agent": True
}