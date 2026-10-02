#!/usr/bin/env kite --allow-net

# hello-ssh connects to a remote machine to retrieve machine info.
# Uses the one-shot ssh.exec("command", args)
result = ssh.exec(
    "uname -a",
    hosts=["remote-host"],
    user="remote-user",
    key="~/.ssh/id_ed25519",
    use_agent=True,
    host_key_check=False
)

# The call returns a slice matching each host
print(result[0].stdout)
