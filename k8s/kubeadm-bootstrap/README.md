# Upstream Kubernetes (Kubeadm) Bootstrapping & Day-2 Management

This tutorial demonstrates how **Starkite** bootstraps and manages an upstream Kubernetes cluster from scratch using standard `kubeadm`—**without requiring a Kubernetes management cluster, Cluster API (CAPI), or temporary local bootstrap clusters**.

---

## The Architecture & The "Root Cluster" Problem

In Kubernetes-native infrastructure tools like Cluster API (CAPI), infrastructure is represented as Custom Resources (`Cluster`, `KubeadmControlPlane`, `MachineDeployment`). Because these resources require an active Kubernetes control plane to reconcile them, operators face the **Root Cluster Dilemma**: *you must already have a running Kubernetes cluster to create a Kubernetes cluster*.

Starkite eliminates this circular dependency by acting as a **zero-dependency orchestration engine**:
1. Operates from a single static binary (`kite`) with zero cluster footprint.
2. Directly orchestrates virtual machines (**Lima VMs** or **Multipass VMs**) via declarative YAML specifications.
3. Prepares host operating systems (kernel modules, sysctl, containerd).
4. Executes standard upstream `kubeadm init`, extracts join tokens dynamically, and joins worker nodes concurrently (`concur.map`).
5. Handles full Day-2 operations: dynamic node scaling, graceful cordoning/draining, and in-place rolling version upgrades.

```
                           Cluster Lifecycle Overview
                           
   1. setup.star       ──► Generates YAML & starts VMs (Lima / Multipass) + installs kubeadm
   2. bootstrap.star   ──► Runs `kubeadm init`, joins workers, applies CNI, verifies Ready
   3. scale.star       ──► Day-2: Dynamically joins worker-3 or drains worker-2
   4. upgrade.star     ──► Day-2: Sequential rolling upgrade (CP -> drain -> node upgrade -> uncordon)
```

---

## Prerequisites

* **Starkite CLI (`kite`)**: Ensure `kite` is in your `PATH` (`kite version`).
* **Virtualization Driver**:
  - **Lima VMs** (Recommended on macOS): `brew install lima` (`limactl version`).
  - **Multipass VMs**: `brew install --cask multipass` (`multipass version`).

---

## Step 1: Provision Machines & Install Kubeadm (`setup.star`)

`setup.star` generates machine specification YAMLs (`manifests/lima-*.yaml` or `manifests/multipass-*.yaml`), provisions 3 machines (`k8s-cp`, `k8s-worker-1`, `k8s-worker-2`), and prepares the host operating system:
* Disables Linux swap.
* Loads `overlay` and `br_netfilter` kernel modules.
* Configures sysctl networking (`net.bridge.bridge-nf-call-iptables = 1`, `net.ipv4.ip_forward = 1`).
* Installs `containerd` with `SystemdCgroup = true`.
* Configures official upstream `pkgs.k8s.io` repository and installs `kubelet`, `kubeadm`, and `kubectl`.

```bash
# Start machines and install kubeadm via Lima VMs (default):
kite run ./setup.star --driver lima

# Or start machines via Multipass VMs:
kite run ./setup.star --driver multipass
```

Verify that all machines are online and report `kubeadm` installed:

```bash
kite run ./setup.star --action status --driver lima
```

---

## Step 2: Bootstrap the Upstream Cluster (`bootstrap.star`)

`bootstrap.star` executes the Day-0 and Day-1 initialization sequence:
1. Discovers the control plane IP.
2. Executes `kubeadm init --pod-network-cidr=10.244.0.0/16`.
3. Downloads the cluster `admin.conf` to `./kubeconfig` locally.
4. Generates the join token and concurrently joins `k8s-worker-1` and `k8s-worker-2` via `concur.map`.
5. Applies the Flannel CNI network plugin.
6. Polls node status until all nodes reach `Ready` state.
7. Deploys a two-replica smoke-test workload to verify scheduling.

```bash
kite run ./bootstrap.star --driver lima
```

**Expected Output:**
```text
=== Starkite Upstream Kubeadm Bootstrap ===
Driver         : lima
Control Plane  : k8s-cp
Workers        : k8s-worker-1, k8s-worker-2
CNI Network    : flannel (CIDR: 10.244.0.0/16)
Kubeconfig Out : ./kubeconfig

[1/5] Initializing control plane node k8s-cp...
  [k8s-cp] Control Plane IP: 192.168.105.10
  [k8s-cp] Running kubeadm init (pod-network-cidr=10.244.0.0/16)...
  [k8s-cp SUCCESS] Control plane initialized successfully.
[2/5] Fetching cluster kubeconfig from k8s-cp...
  [SUCCESS] Kubeconfig saved to ./kubeconfig
[3/5] Generating worker join token on k8s-cp...
  Joining 2 worker nodes concurrently...
  [k8s-worker-1 SUCCESS] Joined cluster successfully.
  [k8s-worker-2 SUCCESS] Joined cluster successfully.
[4/5] Installing Container Network Interface (CNI: flannel)...
  [SUCCESS] Flannel CNI manifests applied.
[5/5] Waiting for all 3 nodes to reach Ready state...
  [SUCCESS] All 3 nodes are in Ready state!

=== Cluster Bootstrap Complete ===

NAME           STATUS   ROLES           AGE     VERSION   INTERNAL-IP
k8s-cp         Ready    control-plane   2m10s   v1.31.0   192.168.105.10
k8s-worker-1   Ready    <none>          75s     v1.31.0   192.168.105.11
k8s-worker-2   Ready    <none>          74s     v1.31.0   192.168.105.12
```

---

## Step 3: Local Cluster Interaction

To interact with the newly bootstrapped cluster from your workstation:

```bash
export KUBECONFIG=$(pwd)/kubeconfig

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
kite run ./setup.star --workers k8s-worker-3 --driver lima

# 2. Join the new worker to the live cluster:
kite run ./scale.star --action join --node k8s-worker-3 --driver lima
```

### Scale In: Safe Node Decommissioning & Eviction
To decommission an existing worker node (`k8s-worker-2`):
1. **Cordons** the node to disable new pod scheduling.
2. **Gracefully drains** running workloads with eviction timeouts.
3. **Deletes** the node record from the Kubernetes API.
4. **Resets** `kubeadm` on the target machine.

```bash
kite run ./scale.star --action drain --node k8s-worker-2 --driver lima
```

---

## Step 5: Day-2 Zero-Downtime Rolling Upgrade (`upgrade.star`)

Demonstrates an in-place rolling version upgrade following the official upstream Kubernetes upgrade runbook:
1. **Control Plane Upgrade**: Upgrades the `kubeadm` package, executes `kubeadm upgrade apply`, and restarts `kubelet`.
2. **Sequential Worker Node Upgrades**: For each worker, cordons the node, evicts pods via `drain`, upgrades `kubeadm`, runs `kubeadm upgrade node`, restarts `kubelet`, and uncordons.
3. **Health Verification Gates**: Asserts that each worker returns to `Ready` status before touching the next node.

```bash
# Upgrade cluster to target version:
kite run ./upgrade.star --version 1.31.2 --driver lima
```

---

## Step 6: Teardown & Clean Up

To stop machines without deleting them:

```bash
kite run ./setup.star --action stop --driver lima
```

To permanently destroy all instances and network configurations:

```bash
kite run ./setup.star --action destroy --driver lima
```

---

## Built-in Starkite Modules & Platform Alignment

To ensure a self-contained automation workflow, these scripts maximize the use of Starkite's built-in standard library:

| Functionality | Standard CLI Approach | Starkite Native Solution | Built-in Module |
|---|---|---|---|
| **Machine YAML Generation** | Arcane bash heredocs & `cat <<EOF` | Structured Starlark dictionary encoding | `yaml.encode` |
| **CNI Manifest Fetching** | Shell `curl` / `wget` commands | In-process HTTP GET with timeout support | `http.get` |
| **Cluster In-Process TLS** | Shell `kubectl` CLI binary | Native Go client-go dynamic client with TLS negotiation | `k8s.config` |
| **Day-2 Node Operations** | `kubectl cordon`, `kubectl drain` | Programmatic node cordon, pod eviction, and deletion | `k8s.cordon`, `k8s.drain` |
| **Cluster Readiness Polling** | `kubectl get nodes -o wide` parsing | Native resource inspection over API conditions | `k8s.list("node")` |
| **Concurrent Worker Join** | Complex bash backgrounding (`&`) | Multi-threaded deterministic task mapping | `concur.map` |

### Architectural Gaps & Future Roadmap

* **Native X.509 / PKI Generation (`pki.*`)**: Starkite has an active proposal ([`starkite-pki-management.md`](../../../project-planning/starkite/starkite-pki-management.md)) for native X.509 certificate and CA management (`pki.ca`, `pki.sign`, `pki.inspect`). Until implemented, Kubernetes CA generation and API server SAN issuance are handled by `kubeadm init` and `kubeadm init phase certs apiserver`.
* **ASN.1 / SubjectPublicKeyInfo Extraction**: The `kubeadm join` token CA cert hash requires SHA-256 over the DER-encoded `SubjectPublicKeyInfo`. Once the `pki` module is introduced, Starkite will compute this directly from `ca.crt` using `hash.bytes(...)` without relying on `kubeadm token create`.

---

## Comparison: Cluster API vs. Starkite Standalone

| Lifecycle Dimension | Cluster API (CAPI) | Starkite Bootstrapper |
|---|---|---|
| **Prerequisites** | Dedicated management cluster, etcd, 20+ CRDs, 4–6 controller pods | Single static binary (`kite`, ~20MB) |
| **Day-0 Bootstrap** | Chicken-and-egg: requires local `kind` cluster + complex `clusterctl move` | Direct orchestration over SSH / local hypervisors |
| **Node Scalability** | Modifies `MachineDeployment` CRDs | Direct programmatic `concur.map` execution |
| **Bare-Metal Support** | Assumes disposable VMs | Native in-place cordoning, draining, and package upgrades |
| **Footprint & Speed** | High memory overhead; multi-minute CRD reconciliation loops | Cold start < 15ms; deterministic script execution |
