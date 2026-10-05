# Upstream Kubernetes (Kubeadm) Bootstrapping & Day-2 Management

This tutorial demonstrates how **Starkite** bootstraps and manages an upstream Kubernetes cluster from scratch using standard `kubeadm`—**without requiring a Kubernetes management cluster, Cluster API (CAPI), or temporary local bootstrap clusters**.

---

## The Architecture & The "Root Cluster" Problem

In Kubernetes-native infrastructure tools like Cluster API (CAPI), infrastructure is represented as Custom Resources (`Cluster`, `KubeadmControlPlane`, `MachineDeployment`). Because these resources require an active Kubernetes control plane to reconcile them, operators face the **Root Cluster Dilemma**: *you must already have a running Kubernetes cluster to create a Kubernetes cluster*.

Starkite eliminates this circular dependency by acting as a **zero-dependency orchestration engine**:
1. Operates from a single static binary (`kite`) with zero cluster footprint.
2. Directly orchestrates virtual machines (**Lima VMs**) via declarative YAML specifications with embedded OS and runtime provisioning.
3. Isolates all generated cluster manifests and kubeconfig files under `~/.starkite/tutorials/k8s/` to prevent repository leakage.
4. Executes standard upstream `kubeadm init`, extracts join tokens dynamically, and joins worker nodes concurrently (`concur.map`).
5. Handles full Day-2 operations: dynamic node scaling, graceful cordoning/draining, and in-place rolling version upgrades.

```
                           Cluster Lifecycle Overview
                           
   1. setup.star       ──► Generates YAML & starts Lima VMs with embedded containerd/kubeadm
   2. bootstrap.star   ──► Runs `kubeadm init`, joins workers, applies CNI, deploys smoke-test.yaml
   3. scale.star       ──► Day-2: Dynamically joins worker-3 or drains worker-2
   4. upgrade.star     ──► Day-2: Sequential rolling upgrade (CP -> drain -> node upgrade -> uncordon)
```

---

## Prerequisites

* **Starkite CLI (`kite`)**: Ensure `kite` is in your `PATH` (`kite version`).
* **Virtualization Engine**:
  - **Lima VMs**: `brew install lima` (`limactl version`).

---

## Step 1: Provision Machines & Install Kubeadm (`setup.star`)

`setup.star` generates machine specification YAMLs (`~/.starkite/tutorials/k8s/manifests/lima-*.yaml`), provisions 3 machines (`k8s-cp`, `k8s-worker-1`, `k8s-worker-2`), and embeds complete system provisioning directly into Lima's cloud-init specification:
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

## Step 2: Bootstrap the Upstream Cluster (`bootstrap.star`)

`bootstrap.star` executes the Day-0 and Day-1 initialization sequence:
1. Verifies bidirectional network connectivity across all nodes (`common.verify_cluster_mesh`).
2. Executes `kubeadm init --pod-network-cidr=10.244.0.0/16` with localhost SAN injection (`127.0.0.1,localhost`).
3. Downloads the cluster `admin.conf` to `~/.starkite/tutorials/k8s/kubeconfig`.
4. Generates the join token and concurrently joins `k8s-worker-1` and `k8s-worker-2` via `concur.map`.
5. Applies the Flannel CNI network plugin via `http.url().get()` and `k8s.apply()`.
6. Polls node status until all nodes reach `Ready` state.
7. Deploys the static smoke-test workload (`smoke-test.yaml`) to verify scheduling and networking.

```bash
kite run ./bootstrap.star
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

=== Cluster Bootstrap Complete ===

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

## Step 4: Day-2 Dynamic Node Scaling (`scale.star`)

Demonstrates automated worker lifecycle management without manual node intervention.

### Scale Out: Join a New Worker Node
To provision and join an additional node (`k8s-worker-3`):

```bash
# 1. Start the machine instance if not already running:
kite run ./setup.star --workers k8s-worker-3

# 2. Join the new worker to the live cluster:
kite run ./scale.star --action join --node k8s-worker-3
```

### Scale In: Safe Node Decommissioning & Eviction
To decommission an existing worker node (`k8s-worker-2`):
1. **Cordons** the node to disable new pod scheduling (`k8s.cordon`).
2. **Gracefully drains** running workloads with eviction timeouts (`k8s.drain`).
3. **Deletes** the node record from the Kubernetes API (`k8s.delete`).
4. **Resets** `kubeadm` on the target machine.

```bash
kite run ./scale.star --action drain --node k8s-worker-2
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

To permanently destroy all instances and network configurations:

```bash
kite run ./setup.star --action destroy
```

---

## Modular File Architecture

```
k8s/kubeadm-bootstrap/
├── README.md          # End-to-end tutorial guide and runbook
├── lima.star          # Lima VM abstraction: YAML generation, JSON inspection, and lifecycle
├── common.star        # Cross-node connectivity checks and Kubernetes client factory
├── setup.star         # Phase 1: Machine launching and embedded OS/package provisioning
├── bootstrap.star     # Phase 2: Kubeadm initialization, join orchestration, CNI, smoke test
├── scale.star         # Day-2: Dynamic worker scaling (scale out / cordon & drain)
├── upgrade.star       # Day-2: In-place zero-downtime rolling upgrades
└── smoke-test.yaml    # Declarative workload manifest used for cluster verification
```

Runtime artifacts are generated outside the source repository under `~/.starkite/tutorials/k8s/`:
* `manifests/lima-*.yaml`: Per-node machine specifications
* `kubeconfig`: Cluster administrative credentials
