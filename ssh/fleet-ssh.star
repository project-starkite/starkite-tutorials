#!/usr/bin/env kite --allow-net

# my_fleet is a fleet constructor function.
# A fleet can also be constructed from other sources:
# - list of resource object
# - a file (custom or host files)
# - json object
def my_fleet():
    return [{"name": "node-1"}]

def main():
    # fleet only supported in ssh.config constructor methods
    client = ssh.config(
        fleet=my_fleet(),
        host_key_check=False,
        auth={
            "user": "deploy",
            "key": "~/.ssh/id_ed25519",
            "use_agent": True,
        }
    )

    result = client.exec("uname -a")

    print(result[0].stdout)