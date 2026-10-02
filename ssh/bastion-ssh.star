#!/usr/bin/env kite --allow-net

# This example demonstrates using starkite 
# for bastion-based ssh connection.

def main():
    client = ssh.config(
        host_key_check=False,
        hosts=["node-1"],

        auth={
            "user": "ubuntu",
            "use_agent": True
        },

        jump={
            "host": "jump-host",
            "user": "jumpuser",
            "key": "~/.ssh/id_ed25519",
            "use_agent": True,
        }

    )

    client.copy_id(
        key="~/.ssh/id_ed25519.pub",
        prompt=False,
        key_check=True,
    )

    result = client.exec("uname -a && hostname")

    print(result[0].stdout)