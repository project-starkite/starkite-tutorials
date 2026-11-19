#!/usr/bin/env kite
"""Provision a central Kubernetes hub and a fleet of Podman edge hosts over SSH.

Uses Starkite's built-in ssh module to generate a temporary Ed25519 key pair,
distribute it to the hub and edge nodes (optionally via the hub as a jump host),
install a kubelet-free k3s control plane on the hub, mint a least-privilege
ServiceAccount kubeconfig, provision rootless Podman and kite across edge hosts,
and launch site-scoped edge_agent.star services.
"""

DEFAULT_HUB_USER = "alice"
DEFAULT_EDGE_USER = "edgeops"
DEFAULT_NAMESPACE = "edge-fleet"
DEFAULT_POLL = "10s"
DEFAULT_KITE_VERSION = "v0.12.0"
DEFAULT_TOKEN_DURATION = "24h"
HUB_MANIFEST_FILES = [
    "namespace.yaml",
    "rbac-agent.yaml",
    "crd-containerapp.yaml",
    "setup.star",
]

def parse_cli():
    args.string("hub-host", required = True, help = "SSH hostname or IP of the central hub host (e.g. hub-01.example.local)")
    args.string("hub-ip", default = "", help = "LAN IP for k3s --tls-san and agent kubeconfig (defaults to --hub-host)")
    args.string("hub-user", default = DEFAULT_HUB_USER, help = "SSH username on the hub host")
    args.string("edge-hosts", required = True, help = "Comma-separated edge hostnames or IPs (e.g. edge-01,edge-02,edge-03,edge-04)")
    args.string("edge-user", default = DEFAULT_EDGE_USER, help = "SSH username on edge hosts")
    args.string("namespace", shorthand = "n", default = DEFAULT_NAMESPACE, help = "Kubernetes namespace for edge workloads and RBAC")
    args.string("poll", default = DEFAULT_POLL, help = "Periodic drift-detection reconciliation interval for edge agents")
    args.string("kite-version", default = DEFAULT_KITE_VERSION, help = "Starkite release tag to install on hub and edge hosts")
    args.string("token-duration", default = DEFAULT_TOKEN_DURATION, help = "Lifetime of the minted edge-agent ServiceAccount token")
    args.string("key-path", default = "", help = "Optional path for generated temporary SSH key (defaults to temp dir)")
    args.bool("use-jump", default = True, help = "Connect to edge hosts using --hub-host as an SSH bastion jump host")
    return args.parse()

def parse_hosts(csv_hosts):
    """Split a comma-separated host string into clean non-empty hostnames."""
    hosts = []
    for raw in csv_hosts.split(","):
        cleaned = raw.strip()
        if cleaned:
            hosts.append(cleaned)
    return hosts

def site_name_for_index(idx):
    """Map a zero-based host index to a deterministic site identifier."""
    return "site-%d" % (idx + 1)

def build_kubeconfig(server_url, ca_data, token, namespace):
    """Render a least-privilege kubeconfig scoped to ServiceAccount/edge-agent."""
    lines = [
        "apiVersion: v1",
        "kind: Config",
        "clusters:",
        "- name: hub",
        "  cluster:",
        "    server: %s" % server_url,
        "    certificate-authority-data: %s" % ca_data,
        "contexts:",
        "- name: edge-agent",
        "  context:",
        "    cluster: hub",
        "    namespace: %s" % namespace,
        "    user: edge-agent",
        "current-context: edge-agent",
        "users:",
        "- name: edge-agent",
        "  user:",
        "    token: %s" % token,
    ]
    return "\n".join(lines) + "\n"

def agent_launch_cmd(site, namespace, poll):
    """Build the systemd-run --user command launching edge_agent.star on an edge host."""
    return (
        "export XDG_RUNTIME_DIR=/run/user/$(id -u); " +
        "systemctl --user stop starkite-edge-agent 2>/dev/null || true; " +
        "systemctl --user reset-failed starkite-edge-agent 2>/dev/null || true; " +
        "systemctl --user start podman.socket; " +
        "SBX_FLAGS='--sandbox-enabled=false'; " +
        "if grep -qw landlock /sys/kernel/security/lsm 2>/dev/null; then " +
        "SBX_FLAGS=\"--sandbox-profile=sandbox-net --sandbox-path-read=$HOME/.kube/edge-agent.yaml --sandbox-path-write=$XDG_RUNTIME_DIR/podman --env KUBECONFIG --env XDG_RUNTIME_DIR\"; " +
        "fi; " +
        "systemd-run --user --unit=starkite-edge-agent " +
        "--working-directory=\"$HOME/edge-containers\" " +
        "--setenv=\"KUBECONFIG=$HOME/.kube/edge-agent.yaml\" " +
        "--setenv=\"XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR\" " +
        "sh -c \"exec \\\"$HOME/.local/bin/kite\\\" run ./edge_agent.star " +
        "--site=%s --namespace=%s --poll=%s --timeout=0 $SBX_FLAGS\"" % (site, namespace, poll)
    )

def require_ok(results, step):
    """Fail with a concise host error summary if any SSH command failed."""
    for res in results:
        if not res.ok:
            fail("%s failed on %s: %s" % (step, res.host, res.stderr.strip()))

def provision(cli):
    """Provision the hub control plane and edge fleet end to end."""
    edge_hosts = parse_hosts(cli.edge_hosts)
    if len(edge_hosts) == 0:
        fail("--edge-hosts must contain at least one host")
    hub_ip = cli.hub_ip or cli.hub_host
    key_path = cli.key_path or fs.path(os.temp_dir()).join("edge_fleet_key").string

    # 1. Generate a scoped temporary Ed25519 key pair locally and authorize it on the hub.
    keys = ssh.keygen(
        type = "ed25519",
        comment = "starkite-edge-fleet",
        path = key_path,
        overwrite = True,
    )
    log.info("Generated temporary fleet SSH key", attrs = {"path": keys.path, "fingerprint": keys.fingerprint})

    hub_bootstrap = ssh.config(
        hosts = [cli.hub_host],
        auth = {"user": cli.hub_user, "use_agent": True},
        host_key_check = False,
    )
    require_ok(hub_bootstrap.copy_id(key = keys.pub_path, prompt = False, key_check = True), "copy_id hub")

    hub = ssh.config(
        hosts = [cli.hub_host],
        auth = {"user": cli.hub_user, "key": keys.path},
        host_key_check = False,
    )

    # 2. Authorize the temporary key across all edge hosts (using EDGE_NODE_PASSWORD on first touch if set).
    edge_auth = {"user": cli.edge_user, "use_agent": True}
    edge_pwd = os.env("EDGE_NODE_PASSWORD")
    if edge_pwd:
        edge_auth = {"user": cli.edge_user, "password": edge_pwd}

    jump_cfg = {"host": cli.hub_host, "user": cli.hub_user, "key": keys.path, "host_key_check": False} if cli.use_jump else None
    edge_bootstrap = ssh.config(
        hosts = edge_hosts,
        auth = edge_auth,
        jump = jump_cfg,
        host_key_check = False,
        exec_policy = "concurrent",
    )
    require_ok(edge_bootstrap.copy_id(key = keys.pub_path, prompt = False), "copy_id edge hosts")

    # 3. Install kubelet-free k3s hub control plane + kite on hub-01 and run setup.star.
    hub_install_cmd = (
        "set -euo pipefail; " +
        "mkdir -p \"$HOME/.local/bin\" \"$HOME/.kube\" \"$HOME/edge-containers\"; " +
        "if ! command -v k3s >/dev/null 2>&1; then " +
        "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"server --disable-agent --disable=traefik,servicelb --write-kubeconfig-mode=644 --tls-san=%s --tls-san=%s\" sh -; " % (hub_ip, cli.hub_host) +
        "fi; " +
        "for i in $(seq 1 30); do kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get --raw=/readyz 2>/dev/null | grep -qx ok && break; sleep 2; done; " +
        "cp /etc/rancher/k3s/k3s.yaml \"$HOME/.kube/config\"; " +
        "sed -i \"s/127\\.0\\.0\\.1/%s/g\" \"$HOME/.kube/config\"; " % hub_ip +
        "if [ ! -x \"$HOME/.local/bin/kite\" ]; then " +
        "curl -fsSL https://raw.githubusercontent.com/project-starkite/starkite/%s/scripts/install.sh | PREFIX=\"$HOME/.local/bin\" STARKITE_VERSION=%s sh; " % (cli.kite_version, cli.kite_version) +
        "fi"
    )
    require_ok(hub.exec(hub_install_cmd), "install hub k3s and kite")

    for fname in HUB_MANIFEST_FILES:
        require_ok(hub.upload(fname, "$HOME/edge-containers/" + fname), "upload " + fname)

    setup_cmd = (
        "cd \"$HOME/edge-containers\" && " +
        "KUBECONFIG=\"$HOME/.kube/config\" \"$HOME/.local/bin/kite\" run ./setup.star " +
        "--namespace=%s --sandbox-enabled=false" % cli.namespace
    )
    require_ok(hub.exec(setup_cmd), "bootstrap hub via setup.star")

    # Mint a least-privilege kubeconfig bound to ServiceAccount/edge-agent.
    ca_res = hub.exec("awk '/certificate-authority-data:/{print $2; exit}' \"$HOME/.kube/config\"")
    require_ok(ca_res, "read hub CA")
    tok_res = hub.exec("kubectl create token edge-agent -n %s --duration=%s" % (cli.namespace, cli.token_duration))
    require_ok(tok_res, "mint edge-agent token")

    scoped_cfg = build_kubeconfig(
        server_url = "https://%s:6443" % hub_ip,
        ca_data = ca_res[0].stdout.strip(),
        token = tok_res[0].stdout.strip(),
        namespace = cli.namespace,
    )
    local_cfg_path = fs.path(os.temp_dir()).join("edge-agent.kubeconfig").string
    fs.write(local_cfg_path, scoped_cfg)

    # 4. Provision Podman (rootless socket + linger) and kite concurrently across all edge hosts.
    edges = ssh.config(
        hosts = edge_hosts,
        auth = {"user": cli.edge_user, "key": keys.path},
        jump = jump_cfg,
        host_key_check = False,
        exec_policy = "concurrent",
    )
    edge_install_cmd = (
        "set -euo pipefail; " +
        "mkdir -p \"$HOME/.local/bin\" \"$HOME/.kube\" \"$HOME/edge-containers\"; " +
        "if ! command -v podman >/dev/null 2>&1; then " +
        "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && " +
        "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman; " +
        "fi; " +
        "sudo loginctl enable-linger \"$USER\"; " +
        "XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user enable --now podman.socket; " +
        "if [ ! -x \"$HOME/.local/bin/kite\" ]; then " +
        "curl -fsSL https://raw.githubusercontent.com/project-starkite/starkite/%s/scripts/install.sh | PREFIX=\"$HOME/.local/bin\" STARKITE_VERSION=%s sh; " % (cli.kite_version, cli.kite_version) +
        "fi"
    )
    require_ok(edges.exec(edge_install_cmd), "provision podman and kite on edge hosts")
    require_ok(edges.upload("edge_agent.star", "$HOME/edge-containers/edge_agent.star"), "upload edge_agent.star")
    up_cfg = edges.upload(local_cfg_path, "$HOME/.kube/edge-agent.yaml", mode = "0600")
    rm_res = fs.try_remove(local_cfg_path)
    if not rm_res.ok:
        log.warn("Failed to remove temporary kubeconfig", attrs = {"path": local_cfg_path, "error": str(rm_res.err)})
    require_ok(up_cfg, "upload scoped kubeconfig")

    # 5. Start a site-scoped starkite-edge-agent user unit on each edge host and probe /healthz.
    for idx, host in enumerate(edge_hosts):
        site = site_name_for_index(idx)
        single = ssh.config(
            hosts = [host],
            auth = {"user": cli.edge_user, "key": keys.path},
            jump = jump_cfg,
            host_key_check = False,
        )
        require_ok(single.exec(agent_launch_cmd(site, cli.namespace, cli.poll)), "start agent on " + host)
        log.info("Started edge agent", attrs = {"host": host, "site": site, "namespace": cli.namespace})

    probe_cmd = "for h in %s; do code=$(curl -sS -o /dev/null -w '%%{http_code}' --connect-timeout 3 \"http://$h:18081/healthz\" || echo ERR); echo \"$h -> HTTP $code\"; done" % " ".join(edge_hosts)
    probe_res = hub.exec("sleep 3 && " + probe_cmd)
    require_ok(probe_res, "probe edge healthz endpoints")
    print(probe_res[0].stdout.strip())

def main():
    cli = parse_cli()
    provision(cli)
