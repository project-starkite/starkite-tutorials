# Starkite Tutorials & Examples

Hands-on tutorials and reference implementations for **[Starkite](https://starkite.dev)** (`kite`), the single-binary automation runtime for cloud-native systems, infrastructure operations, and AI agent tooling.

Starkite embeds Google's **Starlark** language—a deterministic, hermetic Python dialect—inside Go. It exposes Go's standard library and cloud-native primitives as pre-loaded modules for HTTP, OS processes, SSH, Docker/Podman containers, Kubernetes, and the Model Context Protocol (MCP), eliminating the need for package managers, virtual environments, or external interpreters.

---

## Installation

Before running the tutorials, install the all-in-one `kite` binary.

### Package Managers

* **macOS / Linux (Homebrew)**:
  ```bash
  brew install project-starkite/tap/kite
  ```

* **Linux / macOS (Shell Script)**:
  ```bash
  curl -fsSL https://starkite.run/install.sh | sh
  ```

* **Windows (PowerShell)**:
  ```powershell
  irm https://starkite.run/install.ps1 | iex
  ```

* **Windows (Scoop)**:
  ```powershell
  scoop bucket add starkite https://github.com/project-starkite/scoop-bucket
  scoop install kite
  ```

### Pre-Built Binaries

Download release archives for your platform from [GitHub Releases](https://github.com/project-starkite/starkite/releases) (`kite-darwin-arm64`, `kite-linux-amd64`, `kite-windows-amd64.exe`, etc.). Place the binary in your `PATH` and ensure it is executable:

```bash
chmod +x kite
sudo mv kite /usr/local/bin/
```

### Build from Source

Build directly with the Go toolchain (requires Go 1.22+):

```bash
git clone https://github.com/project-starkite/starkite.git
cd starkite
make kite
sudo cp ./bin/kite /usr/local/bin/
```

### Verify Installation

Verify that the CLI is installed and accessible:

```bash
kite version
```

---

## Tutorial Catalog

Each directory provides standalone, runnable Starlark scripts alongside walkthrough documentation:

### 1. Kubernetes Operations (`k8s/`)

Tutorials covering the 3-tier architecture of Starkite's `k8s` module, from resource primitives to active reconciliation controllers and custom resource operators.

* [`k8s/README.md`](k8s/README.md): Complete module walkthrough and operational guide.
* [`01-hello-k8s.star`](k8s/01-hello-k8s.star): Cluster discovery, version inspection, and node querying.
* [`02-crud-resources.star`](k8s/02-crud-resources.star): Declarative resource CRUD lifecycle, selectors, and patches.
* [`03-obj-constructors.star`](k8s/03-obj-constructors.star): Typed object schemas (`k8s.obj.*`), workload flattening, and YAML export.
* [`04-workload-ops.star`](k8s/04-workload-ops.star): Imperative operations without YAML (`deploy`, `scale`, `rollout`, `set_image`).
* [`05-pod-exec-logs.star`](k8s/05-pod-exec-logs.star): Pod diagnostics, command execution (string and list syntax), and log streaming.
* [`06-node-ops.star`](k8s/06-node-ops.star): Node maintenance (`cordon`, `uncordon`, allocatable resource inspection).
* [`07-controller.star`](k8s/07-controller.star): Active reconciliation controller with drift detection and health endpoints.
* [`08-leader-election.star`](k8s/08-leader-election.star): High-availability controllers using distributed `Lease` locking.
* [`09-admission-webhook.star`](k8s/09-admission-webhook.star): Validating and mutating HTTPS admission webhook servers.
* [`10-crd-operator.star`](k8s/10-crd-operator.star): Complete CustomResourceDefinition (CRD) operator pattern with child management.
* [`11-cluster-auditor.star`](k8s/11-cluster-auditor.star): Multi-namespace reliability, security, and governance auditor.
* [`12-multi-protocol-onboarding.star`](k8s/12-multi-protocol-onboarding.star): Multi-protocol tenant onboarding (relational SQL migrations + K8s workloads).
* [`kubeadm-cluster/`](k8s/kubeadm-cluster/): Upstream Kubernetes cluster lifecycle, Day-2 scaling, and rolling upgrades via Lima VMs.
* [`k3s-bootstrap/`](k8s/k3s-bootstrap/): Multi-node k3s cluster provisioning via SSH jump host orchestration.
* [`init-cluster/`](k8s/init-cluster/): Sandboxed Kubernetes init containers with inline `kite eval`, CEL manifest validation, and zero-trust runtime confinement.

### 2. Model Context Protocol (`mcp/`)

Tutorials demonstrating how to build tool servers connecting AI assistants (Claude Desktop, Gemini CLI, Cursor) to external platforms.

* [`mcp/clickup/README.md`](mcp/clickup/README.md): Guide to building a ClickUp tool server in under 80 lines of Starlark.
* [`mcp/clickup/clickup_mcp.star`](mcp/clickup/clickup_mcp.star): Dual-transport (stdio and HTTP) MCP server with automatic schema inference.

### 3. Remote Systems & SSH Automation (`ssh/`)

Tutorials demonstrating multi-host orchestration, bastion jump tunnels, and credential management.

* [`ssh/hello-ssh.star`](ssh/hello-ssh.star): One-shot remote command execution (`ssh.exec`).
* [`ssh/fleet-ssh.star`](ssh/fleet-ssh.star): Inventory-based fleet execution using `ssh.config`.
* [`ssh/bastion-ssh.star`](ssh/bastion-ssh.star): Multi-hop bastion jump host traversal and key copying.
* [`ssh/keygen-ssh.star`](ssh/keygen-ssh.star): Programmatic Ed25519 key generation and distribution.

### 4. Container Management (`containers/`)

Tutorials using Docker and Podman daemon APIs for local container orchestration.

* [`containers/01-hello-containers.star`](containers/01-hello-containers.star): Daemon ping, endpoint inspection, and engine version querying.
* [`containers/02-container-exec.star`](containers/02-container-exec.star): Lifecycle management, in-container process execution, and defer cleanup.

### 5. Windows Automation (`windows/`)

Tutorials demonstrating host operations, process management, and service self-healing on Windows.

* [`windows/README.md`](windows/README.md): Detailed walkthrough for Windows service monitoring, backoff recovery, and HTTP health validation.
* [`windows/service-watchdog.star`](windows/service-watchdog.star): Self-healing watchdog monitoring the Windows Service Control Manager via PowerShell JSON.

### 6. Zero-Trust Sandboxing & Security Architecture (`sandbox/`)

Comprehensive 10-part tutorial suite demonstrating OS-level kernel isolation, capability profiles, filesystem mounts, in-VM call gates, cross-platform kernel drivers, and agentic AI evaluation.

* [`sandbox/README.md`](sandbox/README.md): Master catalog, security architecture, capability ladder, and execution triad.
* [`01-zero-trust-ladder/`](sandbox/01-zero-trust-ladder/README.md): Stepping through the 5 capability rungs (`deny-all` to `unconfined`).
* [`02-native-binary-exec/`](sandbox/02-native-binary-exec/README.md): Direct native binary and Python confinement via `kite exec`.
* [`03-mounts-and-scratch/`](sandbox/03-mounts-and-scratch/README.md): Granular host mounts (`--sandbox-mount`), tmpfs scratch, and $W\oplus X$ enforcement.
* [`04-network-confinement/`](sandbox/04-network-confinement/README.md): Network air-gapping, endpoint allowlists, and automated DNS/TLS certificate unveiling.
* [`05-in-vm-call-gates/`](sandbox/05-in-vm-call-gates/README.md): Fine-grained Starlark API gates (`calls.allow` and `calls.deny`) with deny-first semantics.
* [`06-env-sanitization/`](sandbox/06-env-sanitization/README.md): 3-tier environment synthesis, ambient secret scrubbing, and `--debug` diagnostics.
* [`07-cross-platform-drivers/`](sandbox/07-cross-platform-drivers/README.md): Kernel drivers across Linux (Landlock), macOS (Seatbelt), and Windows (AppContainers).
* [`08-container-drivers/`](sandbox/08-container-drivers/README.md): Ephemeral hardened OCI containers (`podman`, `docker`, `nerdctl`, `gvisor`).
* [`09-module-trust-boundaries/`](sandbox/09-module-trust-boundaries/README.md): Declarative `mod.yaml` manifests and the Non-Escalation Principle.
* [`10-agentic-ai-eval/`](sandbox/10-agentic-ai-eval/README.md): Sandboxed evaluation of untrusted AI-generated code and Model Context Protocol (MCP) tool loops.


---

## Running the Examples

Run scripts using `kite run`:

```bash
# Execute with required permissions
kite run ./script.star --allow-net

# Provide script variables
kite run ./script.star --var key=value --allow-all

# Inspect script options
kite run ./script.star --help
```

### Sandboxing & Permissions

By default, Starkite operates in `deny-all` mode to prevent unintended host access. Grant specific capabilities as needed:

* `--allow-net`: Grants outbound network and HTTP/socket access.
* `--allow-fs`: Grants local filesystem read/write access.
* `--allow-local`: Authorizes local resource binding (stdio, local servers).
* `--sandbox-net-allow`: Grants outbound network access (use `--sandbox-net-allow` or `--sandbox-net-allow=*` for full host access, or `--sandbox-net-allow=<endpoint>` for specific destinations).
* `--allow-all`: Enables all runtime capabilities for development and local testing.

---

## Resources & Links

* **Website**: [starkite.dev](https://starkite.dev)
* **Core Repository**: [github.com/project-starkite/starkite](https://github.com/project-starkite/starkite)
* **Documentation**: [starkite.dev/docs](https://starkite.dev/docs)
* **CLI Reference**: [starkite.dev/references/cli](https://starkite.dev/references/cli)
* **API Documentation**: [starkite.dev/references/api](https://starkite.dev/references/api)
