#!/usr/bin/env kite --allow-net

# generate temporary keys

cluster_nodes = [
    "node-0",
    "node-1",
    "node-2",
    "node-3",
    "node-4",
    "node-5",
]
cluster_user="ubuntu"
bastion_user="jumpuser"
bastion_host="jump-host"
bastion_key="~/.ssh/id_ed25519"

client = ssh.config(
    host_key_check=False,
    hosts=cluster_nodes,

    auth={
        "user": cluster_user,
    },

    jump={
        "host": bastion_host,
        "user": bastion_user,
        "key": bastion_key,
        "use_agent": True,
    }
)

def gen_keys(path):
    return ssh.keygen(
        type       = "ed25519",
        comment    = "cluster-admin-2026",
        path       = path,
        overwrite  = True,
    )

def main():
    key_path = (fs.path(temp_dir()) / "temp_keys").string

    keys = gen_keys(key_path)

    printf("  Key Type:    %s\n", keys.type)
    printf("  Fingerprint: %s\n", keys.fingerprint)
    printf("  Private Key: %s\n", keys.path)
    printf("  Public Key:  %s\n", keys.pub_path)
    printf("  Public Key Content: %s\n", keys.public_key.strip())

    # distribute temporary
    results = client.copy_id(key=keys.pub_path, key_check=True)

    # check key
    println(client.exec("ls ~/.ssh/"))


