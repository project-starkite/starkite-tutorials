# Kubeadm Cluster Bootstrap & Local Machine Setup

This directory provides scripts to provision local machines and prepare them for upstream Kubernetes (`kubeadm`) bootstrapping without requiring a Kubernetes management cluster.

## Architecture

The setup prepares a standard multi-node Kubernetes cluster topology:
* **Control Plane Node** (`k8s-cp`): Runs the Kubernetes API server, controller-manager, scheduler, and etcd.
* **Worker Nodes** (`k8s-worker-1`, `k8s-worker-2`): Run workloads and join the control plane.

The `setup.star` script supports two local virtualization drivers:
1. **Lima VMs (`driver=lima`)**: Native QEMU/Virtualization.framework Linux VMs on macOS with independent IPs and systemd.
2. **Podman Containers (`driver=podman`)**: Systemd-enabled privileged containers running on a dedicated bridge network (`k8s-cluster`).

---

## What `setup.star` Automates

For each configured node, `setup.star` executes:
1. **Machine Lifecycle**: Creates and starts the VM or container if not already running.
2. **OS & Kernel Preparation**:
   - Disables Linux swap (`swapoff -a`).
   - Loads `overlay` and `br_netfilter` kernel modules.
   - Configures sysctl parameters (`net.bridge.bridge-nf-call-iptables = 1`, `net.ipv4.ip_forward = 1`).
3. **Container Runtime Setup**:
   - Installs `containerd`.
   - Generates default configuration and enables `SystemdCgroup = true`.
   - Restarts and enables the `containerd` systemd service.
4. **Kubernetes Tooling Download & Installation**:
   - Configures the official upstream apt repository (`pkgs.k8s.io`).
   - Installs `kubeadm`, `kubelet`, and `kubectl` matching the requested version (default: `1.31`).
   - Holds package versions to prevent unintended upgrades (`apt-mark hold`).
   - Enables the `kubelet` service.
5. **Verification**:
   - Queries `kubeadm version` and `containerd --version` on each node.

---

## Prerequisites

* **Starkite CLI (`kite`)**: Ensure `kite` is in your `PATH` (`kite version`).
* **Virtualization Driver**:
  - For Lima: `brew install lima` (`limactl version`).
  - For Podman: `brew install podman` and an active podman machine (`podman machine start`).

---

## Usage

### 1. Start Machines and Install Kubeadm (Default: Lima)

Provisions the control plane and two worker nodes, then downloads and configures `kubeadm`:

```bash
kite run ./setup.star --var driver=lima
```

To use Podman containers instead:

```bash
kite run ./setup.star --var driver=podman
```

### 2. Customize Node Names, Version, or Resources

```bash
kite run ./setup.star \
  --var driver=lima \
  --var version=1.31 \
  --var cp=k8s-master \
  --var workers=k8s-node-1,k8s-node-2 \
  --var cpus=2 \
  --var memory=2
```

### 3. Check Machine and Kubeadm Status

```bash
kite run ./setup.star --var action=status --var driver=lima
```

### 4. Install Kubeadm on Existing Running Machines

If machines were already started out-of-band and only require package configuration:

```bash
kite run ./setup.star --var action=install-kubeadm --var driver=lima
```

### 5. Stop Machines

Temporarily suspends or stops the instances:

```bash
kite run ./setup.star --var action=stop --var driver=lima
```

### 6. Teardown & Clean Up

Completely removes and deletes the VMs/containers and network bridges:

```bash
kite run ./setup.star --var action=destroy --var driver=lima
```

---

## Next Steps: Cluster Bootstrap

Once `setup.star` reports all nodes are ready with `kubeadm` installed:
1. Initialize the control plane:
   ```bash
   limactl shell k8s-cp sudo kubeadm init --pod-network-cidr=10.244.0.0/16
   ```
2. Retrieve the generated join command:
   ```bash
   limactl shell k8s-cp sudo kubeadm token create --print-join-command
   ```
3. Join the worker nodes using the extracted join command.
