# Upstream Kubernetes (Kubeadm) Lifecycle & Day-2 Management

This tutorial demonstrates the versatility of **Starkite** as an orchestration engine across multi-layered infrastructure environments—from local virtual machine provisioning to upstream Kubernetes cluster bootstrapping and Day-2 operational workflows.

---

## Architecture & Starkite Versatility

Automating Kubernetes infrastructure often requires chaining disparate tools: hypervisor CLIs, configuration managers, remote execution protocols, and Kubernetes-native operators. Tools like Cluster API (CAPI) solve this by declaring infrastructure as Kubernetes Custom Resources, but they introduce the **Root Cluster Dilemma**: *an active Kubernetes management cluster must already exist simply to create or reconcile another cluster*.

Starkite demonstrates its versatility by unifying these layers within a single, consistent scripting model:
1. **Single Static Binary**: Operates from `kite` with zero cluster footprint, running directly on the operator's workstation or CI runner without external management planes.
2. **Multi-Domain Composition**: Seamlessly stitches together virtual machine lifecycle management (**Lima VMs**), declarative file templating (`template.file`), remote execution, and native Kubernetes API manipulation (`k8s` module).
3. **Rootless Bootstrap Capability**: Because Starkite bridges host-level virtualization and Kubernetes API semantics, it easily solves root-cluster bootstrapping scenarios—provisioning VMs from raw images, initializing `kubeadm`, joining workers concurrently (`concur.map`), applying networking, and verifying workloads.
4. **Day-2 Operational Control**: The same scripts manage full Day-2 lifecycles: dynamic worker addition, graceful workload cordoning and draining, live status inspection, and rolling zero-downtime version upgrades.
5. **Clean Workspace Isolation**: Dynamic runtime artifacts (per-instance machine specifications and administrative kubeconfig) are isolated in `~/.starkite/tutorials/k8s/`, ensuring zero repository leakage.

```
                           Cluster Lifecycle Overview
                           
   1. setup.star    ──► Generates YAML & starts Lima VMs with embedded containerd/kubeadm
   2. cluster.star  ──► Day-0/1: Bootstraps control plane, joins workers, applies CNI, smoke test
                        Day-2: Dynamically adds (add-node) or decommissions (remove-node) workers
   3. upgrade.star  ──► Day-2: Sequential rolling upgrade (CP -> drain -> node upgrade -> uncordon)
```

---

## Prerequisites

* **Starkite CLI (`kite`)**: Ensure `kite` is in your `PATH` (`kite version`).
* **Virtualization Engine**:
  - **Lima VMs**: `brew install lima` (`limactl version`).

---

## Step 1: Provision Machines & Install Kubeadm (`setup.star`)

`setup.star` renders machine specifications from `cloud-init-template.yaml` (saved to `~/.starkite/tutorials/k8s/manifests/lima-*.yaml`), provisions 3 machines (`k8s-cp`, `k8s-worker-1`, `k8s-worker-2`), and embeds complete system provisioning directly into Lima's declarative cloud-init specification:
* Disables Linux swap (`swapoff -a`, removes swap from `/etc/fstab`).
* Loads `overlay` and `br_netfilter` kernel modules.
* Configures sysctl networking (`net.bridge.bridge-nf-call-iptables = 1`, `net.ipv4.ip_forward = 1`).
* Installs `containerd` with `SystemdCgroup = true`.
* Configures official upstream `pkgs.k8s.io` repository and installs `kubelet`, `kubeadm`, and `kubectl`.

```bash
# Start machines and provision prerequisites via Lima:
kite run ./setup.star
```

Verify that all machines are online and report `kubeadm` installed:

```bash
kite run ./setup.star --action status
```

---

## Step 2: Bootstrap the Upstream Cluster (`cluster.star`)

`cluster.star` executes the Day-0 and Day-1 initialization sequence:
1. Verifies bidirectional network connectivity across all nodes (`common.verify_cluster_mesh`).
2. Executes `kubeadm init --pod-network-cidr=10.244.0.0/16` with localhost SAN injection (`127.0.0.1,localhost`).
3. Downloads the cluster `admin.conf` to `~/.starkite/tutorials/k8s/kubeconfig`.
4. Generates the join token and concurrently joins `k8s-worker-1` and `k8s-worker-2` via `concur.map`.
5. Applies the Flannel CNI network plugin via `http.url().get()` and `k8s.apply()`.
6. Polls node status until all nodes reach `Ready` state.
7. Deploys the static smoke-test workload (`smoke-test.yaml`) to verify scheduling and networking.

```bash
kite run ./cluster.star
```

**Expected Output:**
```text
=== Starkite Upstream Kubeadm Bootstrap ===
Driver         : lima
Control Plane  : k8s-cp
Workers        : k8s-worker-1, k8s-worker-2
CNI Network    : flannel (CIDR: 10.244.0.0/16)
Kubeconfig Out : ~/.starkite/tutorials/k8s/kubeconfig

[Pre-flight] Verifying node prerequisites and network mesh...
  [SUCCESS] All nodes prepared and network mesh verified.

[1/5] Initializing control plane node k8s-cp...
  [k8s-cp] Control Plane IP: 192.168.104.3
  [k8s-cp] Running kubeadm init (pod-network-cidr=10.244.0.0/16)...
  [k8s-cp SUCCESS] Control plane initialized successfully.
[2/5] Fetching cluster kubeconfig from k8s-cp...
  [SUCCESS] Kubeconfig saved to ~/.starkite/tutorials/k8s/kubeconfig (API endpoint: https://127.0.0.1:6443)
[3/5] Generating worker join token on k8s-cp...
  Joining 2 worker nodes concurrently...
  [k8s-worker-1 SUCCESS] Joined cluster successfully.
  [k8s-worker-2 SUCCESS] Joined cluster successfully.
[4/5] Installing Container Network Interface (CNI: flannel)...
  [SUCCESS] Flannel CNI manifests applied natively.
[5/5] Waiting for all 3 nodes to reach Ready state...
  [SUCCESS] All 3 nodes are in Ready state!

Deploying smoke-test workload to verify cluster functionality...
  [SUCCESS] Smoke-test workload applied natively via k8s module.

=== Cluster Status Summary ===

NAME             STATUS     ROLES            VERSION      INTERNAL-IP     
k8s-cp           Ready      control-plane    v1.31.14     192.168.104.3   
k8s-worker-1     Ready      <none>           v1.31.14     192.168.104.4   
k8s-worker-2     Ready      <none>           v1.31.14     192.168.104.5   
```

---

## Step 3: Local Cluster Interaction

To interact with the newly bootstrapped cluster from your workstation:

```bash
export KUBECONFIG=~/.starkite/tutorials/k8s/kubeconfig

kubectl get nodes -o wide
kubectl get pods -A
```

---

## Step 4: Day-2 Dynamic Node Scaling (`cluster.star`)

`cluster.star` manages ongoing worker scaling operations through native Kubernetes API calls and remote node execution.

### Scale Out: Add a Worker Node (`--action add-node`)
To provision and join an additional node (`k8s-worker-3`):

```bash
# 1. Start the machine instance if not already running:
kite run ./setup.star --workers k8s-worker-3

# 2. Add the worker to the live cluster:
kite run ./cluster.star --action add-node --node k8s-worker-3
```

### Scale In: Safe Node Decommissioning & Eviction (`--action remove-node`)
To decommission an existing worker node (`k8s-worker-2`):
1. **Cordons** the node to disable new pod scheduling (`k8s.cordon`).
2. **Gracefully drains** running workloads with eviction timeouts (`k8s.drain`).
3. **Deletes** the node record from the Kubernetes API (`k8s.delete`).
4. **Resets** `kubeadm` on the target machine.

```bash
kite run ./cluster.star --action remove-node --node k8s-worker-2
```

### Inspect Live Cluster Status (`--action status`)
To view current node health and topology directly from the Kubernetes API:

```bash
kite run ./cluster.star --action status
```

---

## Step 5: Day-2 Zero-Downtime Rolling Upgrade (`upgrade.star`)

Demonstrates an in-place rolling version upgrade following the official upstream Kubernetes upgrade runbook:
1. **Control Plane Upgrade**: Upgrades the `kubeadm` package, executes `kubeadm upgrade apply`, and restarts `kubelet`.
2. **Sequential Worker Node Upgrades**: For each worker, cordons the node, evicts pods via `drain`, upgrades `kubeadm`, runs `kubeadm upgrade node`, restarts `kubelet`, and uncordons.
3. **Health Verification Gates**: Asserts that each worker returns to `Ready` status before touching the next node.

```bash
# Upgrade cluster to target version:
kite run ./upgrade.star --version 1.31.2
```

---

## Step 6: Teardown & Clean Up

To stop machines without deleting them:

```bash
kite run ./setup.star --action stop
```

To permanently destroy all instances and clean up runtime manifests:

```bash
kite run ./setup.star --action destroy
```

---

## Modular File Architecture

```
k8s/kubeadm-bootstrap/
├── README.md                 # End-to-end tutorial guide and runbook
├── cloud-init-template.yaml  # Go text/template specification for Lima cloud-init VMs
├── lima.star                 # Lima VM abstraction: template rendering, JSON inspection, lifecycle
├── common.star               # Cross-node connectivity checks and Kubernetes client factory
├── setup.star                # Phase 1: Machine launching and embedded OS/package provisioning
├── cluster.star              # Phase 2 & Day-2: Cluster bootstrap, worker scaling (add/remove), and status
├── upgrade.star              # Day-2: In-place zero-downtime rolling upgrades
└── smoke-test.yaml           # Declarative workload manifest used for cluster verification
```

Runtime artifacts are generated outside the source repository under `~/.starkite/tutorials/k8s/`:
* `manifests/lima-*.yaml`: Per-node machine specifications
* `kubeconfig`: Cluster administrative credentials
