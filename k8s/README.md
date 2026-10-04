# Starkite Kubernetes Module Tutorials

This directory contains standalone Starlark tutorials demonstrating the 3-tier architecture of Starkite's `k8s` module, from core resource primitives to programmatic tools such as active reconciliation controllers, admission webhooks, distributed leader election, and custom resource operators:

- **Tier 1 (Core Operations)**: Declarative CRUD (`apply`, `get`, `list`, `patch`, `label`, `annotate`, `delete`), condition polling (`wait_for`), and pod I/O (`exec`, `logs`).
- **Tier 2 (High-Level Workload & Node Abstractions)**: Imperative operations without YAML (`deploy`, `scale`, `rollout`, `set_image`, `describe`, `cordon`, `uncordon`).
- **Tier 3 (Declarative Object Modeling & Runtime Systems)**: Typed schema constructors (`k8s.obj.*`), YAML export (`k8s.yaml`), controller reconciliation runtime (`k8s.control`), distributed leader election, admission webhooks (`k8s.webhook`), and CustomResourceDefinitions (`k8s.obj.crd`).

---

## Prerequisites

1. **Starkite CLI (`kite`)**: Ensure `kite` is installed and available in your `PATH`.
   ```bash
   kite version
   ```

2. **Kubernetes Cluster**: An active Kubernetes cluster with standard `~/.kube/config` credentials. A local `kind` or `k3s` cluster works directly:
   ```bash
   kubectl cluster-info
   ```

3. **Permissions**: The scripts interact with the cluster API and require network/cluster access flags (e.g. `--allow-all` or `--allow-net`).

---

## Tutorial Index

### Fundamentals & Resource Operations

| Script | Tier | Topic | Key APIs |
|---|---|---|---|
| [`01-hello-k8s.star`](./01-hello-k8s.star) | Tier 1 | Cluster Discovery & Node Inspection | `k8s.config()`, `client.version()`, `client.context()`, `client.list()` |
| [`02-crud-resources.star`](./02-crud-resources.star) | Tier 1 | Declarative Resource CRUD Lifecycle | `client.apply()`, `client.get()`, `client.label()`, `client.annotate()`, `client.list()`, `client.patch()`, `client.delete()`, `client.try_get()` |
| [`03-obj-constructors.star`](./03-obj-constructors.star) | Tier 3 | Typed Object Constructors & YAML Export | `k8s.obj.*`, `k8s.yaml()`, workload flattening, `client.apply()`, `client.wait_for()` |
| [`04-workload-ops.star`](./04-workload-ops.star) | Tier 2 | High-Level Workload Management | `client.deploy()`, `client.scale()`, `client.rollout()`, `client.set_image()`, `client.describe()` |
| [`05-pod-exec-logs.star`](./05-pod-exec-logs.star) | Tier 1 | Pod Execution & Log Inspection | `client.exec()` (string & list syntax), `client.logs()`, exit code handling |
| [`06-node-ops.star`](./06-node-ops.star) | Tier 2 | Node Maintenance Operations | `client.cordon()`, `client.uncordon()`, schedulability verification |

### Programmatic Tools & Controller Runtimes

| Script | Tier | Topic | Key APIs |
|---|---|---|---|
| [`07-controller.star`](./07-controller.star) | Tier 3 | Active Reconciliation Controller | `k8s.control()`, `reconcile()`, `poll`, `health_port`, `k8s.event()` |
| [`08-leader-election.star`](./08-leader-election.star) | Tier 3 | Distributed Leader Election (HA) | `k8s.control(..., leader_election=True)`, `reconcile()`, `/readyz` leader probing, `Lease` locking |
| [`09-admission-webhook.star`](./09-admission-webhook.star) | Tier 3 | Validating & Mutating Admission Webhooks | `k8s.webhook()`, `validate`, `mutate`, RFC 6902 JSONPatch generation |
| [`10-crd-operator.star`](./10-crd-operator.star) | Tier 3 | Custom Resource Definition (CRD) Operator | `k8s.obj.crd()`, functional child return (`[child_dep, child_svc]`), `finalize()`, auto-ownerRef, orphan pruning, `Ready` condition |
| [`11-cluster-auditor.star`](./11-cluster-auditor.star) | Tool | Cluster Policy & Compliance Auditor | Multi-namespace inspection, SPOF detection, security contexts, scoring |

### Platform Engineering & Multi-Protocol Orchestration

| Script / Directory | Tier | Topic | Key APIs |
|---|---|---|---|
| [`12-multi-protocol-onboarding.star`](./12-multi-protocol-onboarding.star) | Platform | Multi-Protocol Tenant Onboarding & Last-Mile Delivery | `sql.open()`, `db.tx()`, `defer()`, `k8s.obj.*`, `k8s.apply()`, `k8s.yaml()` |
| [`kubeadm-bootstrap/`](./kubeadm-bootstrap/) | Infra | Local Machine Provisioning & Kubeadm Setup (Lima / Podman) | `os.sh()`, `concur.map()`, `limactl`, `podman`, `apt-get` |
| [`k3s-bootstrap/`](./k3s-bootstrap/) | Infra | Multi-Node k3s Cluster Provisioning over SSH | `ssh.config()`, jump host proxying, token extraction |

---

## Running the Tutorials

All commands below should be executed from within the `k8s/` directory.

### 1. Cluster Discovery (`01-hello-k8s.star`)

Inspects cluster endpoint, context, Kubernetes version, cluster nodes, and namespaces:

```bash
kite run ./01-hello-k8s.star --allow-all
```

---

### 2. Declarative Resource CRUD (`02-crud-resources.star`)

Walks through the full lifecycle of a resource using standard Starlark dictionaries:
- Applies a manifest (`client.apply`)
- Retrieves by name (`client.get`)
- Applies labels (`client.label`) and annotations (`client.annotate`)
- Filters resources using label selectors (`client.list(labels="env=tutorial,tier=backend")`)
- Updates fields using merge patches (`client.patch`)
- Deletes resources (`client.delete`)
- Verifies deletion using safe error handling (`client.try_get`)

```bash
kite run ./02-crud-resources.star --allow-all
```

---

### 3. Typed Object Constructors & YAML Generation (`03-obj-constructors.star`)

Demonstrates Tier 3 declarative resource construction via `k8s.obj.*`:
- Constructs `deployment`, `service`, `config_map`, `container`, `container_port`, and `service_port` with validation.
- Workload flattening: pass container lists and labels directly to `k8s.obj.deployment` without constructing intermediate `pod_template` and `pod_spec` wrappers.
- Converts resources to single or multi-document YAML via `k8s.yaml()`.
- Applies the typed objects directly with `client.apply()`.
- Polls for availability with `client.wait_for()`.

```bash
kite run ./03-obj-constructors.star --allow-all
```

---

### 4. High-Level Workload Operations (`04-workload-ops.star`)

Demonstrates Tier 2 imperative operations without writing YAML manifests:
- `client.deploy()`: Creates a Deployment and ClusterIP Service in one step.
- `client.wait_for()`: Waits for the `Available` condition.
- `client.scale()`: Scales replica count.
- `client.rollout(action="status")`: Inspects replica rollout progress.
- `client.set_image()`: Updates container image in-place.
- `client.describe()`: Retrieves resource status, conditions, and recent Kubernetes events.
- `client.rollout(action="restart")`: Triggers a rolling restart.

```bash
kite run ./04-workload-ops.star --allow-all
```

---

### 5. Pod Execution and Logs (`05-pod-exec-logs.star`)

Demonstrates Tier 1 Pod diagnostics and I/O:
- Launches a pod running a container with `k8s.obj.pod`.
- Waits for `Ready` condition.
- Executes shell commands via string syntax (`client.exec(pod, "cmd && cmd")`, wrapped in `/bin/sh -c`).
- Executes binary commands via argument lists (`client.exec(pod, ["cat", "/etc/hosts"])`).
- Inspects return fields: `.stdout`, `.stderr`, and `.code`.
- Reads container log output with line limits (`client.logs(pod, tail=5)`).

```bash
kite run ./05-pod-exec-logs.star --allow-all
```

---

### 6. Node Maintenance Operations (`06-node-ops.star`)

Demonstrates Tier 2 node maintenance commands:
- Lists cluster nodes and selects a target node (supports `--var node=<name>`).
- Inspects allocatable CPU and memory resources.
- Cordons the node (`client.cordon(node)`) to mark `spec.unschedulable = True`.
- Verifies scheduling is disabled.
- Uncordons the node (`client.uncordon(node)`) to restore `spec.unschedulable = False`.

```bash
kite run ./06-node-ops.star --allow-all
```

---

### 7. Custom Controller with Active Reconciliation (`07-controller.star`)

Builds an active Kubernetes controller using `k8s.control()`. The controller monitors deployments matching `app=drift-monitor`. If a deployment's replica count exceeds the configured policy (`max_replicas=3`), the controller detects drift and scales the workload back down via Merge Patch:
- **Unified Handler**: Replaces fragmented lifecycle hooks with a single `reconcile(deploy)` handler.
- **Loop Immunity**: Built-in self-echo suppression prevents controller-originated patches from triggering infinite reconciliation cycles.
- **Domain Events**: Emits Kubernetes events attached to the reconciled resource using `k8s.event()`.
- **Health Probes**: Serves embedded HTTP `/healthz` and `/readyz` endpoints (`health_port=8081`).
- **Periodic Resync**: Uses `poll="30s"` to guard against missed watch notifications.

```bash
# Terminal 1: Run the controller
kite run ./07-controller.star --allow-all

# Terminal 2: Test drift correction
kubectl create deployment drift-demo --image=nginx:alpine --replicas=5
kubectl label deployment drift-demo app=drift-monitor --overwrite

# Verify drift correction, inspect emitted event, and query health probe:
kubectl get deployment drift-demo
kubectl get events --field-selector involvedObject.name=drift-demo
curl -i http://localhost:8081/healthz

# Clean up:
kubectl delete deployment drift-demo
```

---

### 8. Distributed Leader Election (`08-leader-election.star`)

Demonstrates High-Availability (HA) controller deployment using distributed `coordination.k8s.io/v1` `Lease` locking. When multiple controller replicas run concurrently, only the elected leader acquires the Lease and executes the `reconcile()` handler. Standby replicas maintain passive informers and take over within ~15s if the leader terminates:
- **Dynamic Readiness Probes**: `/readyz` returns HTTP 200 OK on the active leader and HTTP 503 Service Unavailable on standby replicas.
- **Warm Standby**: Standby replicas keep internal caches synced, minimizing takeover latency upon failover.
- **Lease Inspection**: Inspects holder identity, renewal timestamps, and transition counts directly via Starlark.

```bash
# Terminal 1: Start replica-1 (becomes leader on port 8081)
kite run ./08-leader-election.star --var id=replica-1 --var health_port=8081 --allow-all

# Terminal 2: Start replica-2 (becomes standby on port 8082)
kite run ./08-leader-election.star --var id=replica-2 --var health_port=8082 --allow-all

# Terminal 3: Probe readiness endpoints
curl -i http://localhost:8081/readyz   # HTTP 200 OK (Leader active)
curl -i http://localhost:8082/readyz   # HTTP 503 Service Unavailable (Standby)

# Terminal 3: Inspect the active Lease object
kite run ./08-leader-election.star --var inspect=true --allow-all

# Trigger a reconciliation event:
kubectl create configmap leader-demo-cm --from-literal=role=primary
kubectl label configmap leader-demo-cm app=leader-demo

# Test failover: Terminate replica-1 (Ctrl+C in Terminal 1).
# Replica 2 acquires the lease within ~15s:
curl -i http://localhost:8082/readyz   # Transitions to HTTP 200 OK!

# Clean up:
kubectl delete configmap leader-demo-cm
```

---

### 9. Admission Webhooks (`09-admission-webhook.star`)

Runs an HTTPS admission webhook server handling Kubernetes `AdmissionReview` requests:
- **Validating webhook**: Rejects workloads missing the `team` ownership label or exceeding 5 replicas.
- **Mutating webhook**: Injects default metadata (`managed-by: starkite-admission`, `starkite.io/admitted: true`) and returns an RFC 6902 JSONPatch.

```bash
# Generate temporary TLS certificates (required by Kubernetes admission):
openssl req -x509 -newkey rsa:2048 -keyout /tmp/webhook-key.pem \
    -out /tmp/webhook-cert.pem -days 7 -nodes -subj '/CN=localhost'

# Run the webhook server:
kite run ./09-admission-webhook.star --allow-all

# Test validation rejection (Terminal 2):
curl -s -k -X POST https://localhost:9443/admit \
    -H "Content-Type: application/json" \
    -d '{"apiVersion":"admission.k8s.io/v1","kind":"AdmissionReview","request":{"uid":"req-1","object":{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"bad-deploy"}}}}'

# Test validation passing + mutation injection (Terminal 2):
curl -s -k -X POST https://localhost:9443/admit \
    -H "Content-Type: application/json" \
    -d '{"apiVersion":"admission.k8s.io/v1","kind":"AdmissionReview","request":{"uid":"req-2","object":{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"good-deploy","labels":{"team":"platform"}},"spec":{"replicas":3}}}}'
```

---

### 10. Custom Resource Definition (CRD) Operator (`10-crd-operator.star`)

Demonstrates the Kubernetes Operator Pattern using declarative custom resource definitions combined with the substrate-driven controller runtime:
- **Programmatic CRD**: Defines `StaticSite.tutorial.starkite.io/v1alpha1` with OpenAPI v3 spec and status schema (`k8s.obj.crd()`).
- **Functional Child Return**: `reconcile(site)` returns child resources `[child_dep, child_svc]`.
- **Automatic Ownership**: Injects OwnerReferences pointing to the parent custom resource for automatic cascading deletion.
- **Dynamic Child Watching**: Spawns informers on child kinds so external tampering with child workloads triggers parent re-reconciliation.
- **Server-Side Apply & Pruning**: Applies child resources using SSA (`fieldManager=starkite`) and auto-prunes orphaned child resources.
- **Status Conditions & Events**: Automatically populates `status.conditions` (`Type=Ready, Status=True`) and emits `Normal Reconciled` events.
- **Declarative Finalizers**: Implements `finalize(site)` hook for pre-deletion cleanup with automatic finalizer registration and stripping.
- **Health Probes**: Serves embedded HTTP `/healthz` and `/readyz` endpoints (`health_port=8081`).

```bash
# Terminal 1: Install CRD and run the operator
kite run ./10-crd-operator.star --allow-all

# Terminal 2: Create a sample StaticSite custom resource
kite run ./10-crd-operator.star --var action=sample --allow-all

# Verify child resources, ownership, conditions, and events:
kubectl get staticsites,deployments,services -l managed-by=staticsite-operator
kubectl describe staticsite tutorial-site
kubectl get events --field-selector involvedObject.name=tutorial-site
curl -i http://localhost:8081/healthz

# Test drift correction on child deployment:
kubectl scale deployment tutorial-site --replicas=10
# The child watch triggers reconciliation and scales replicas back to declared count (2)

# Clean up sample and uninstall CRD:
kite run ./10-crd-operator.star --var action=cleanup-sample --allow-all
kite run ./10-crd-operator.star --var action=uninstall-crd --allow-all
```

---

### 11. Cluster Policy & Reliability Auditor (`11-cluster-auditor.star`)

A standalone diagnostic and governance tool that sweeps across namespaces to identify security and reliability risks:
- **Node Health**: Memory, Disk, and PID pressure detection.
- **High Availability**: Single-replica deployment identification (SPOF risk).
- **Resource Governance**: Workloads missing CPU/memory requests or limits.
- **Security Hardening**: Privileged containers and root execution checks.
- **Service Hygiene**: Services with 0 active backing pod endpoints.
- **Scoring**: Calculates an overall cluster health/compliance score (0–100).

```bash
# Audit all cluster namespaces:
kite run ./11-cluster-auditor.star --allow-all

# Audit a single namespace:
kite run ./11-cluster-auditor.star --var namespace=default --allow-all
```

---

### 12. Multi-Protocol Platform Onboarding & Last-Mile Delivery (`12-multi-protocol-onboarding.star`)

Demonstrates multi-protocol environment provisioning by unifying relational database schema operations and Kubernetes workload deployment into a single, atomic platform workflow. Traditional infrastructure provisioning tools typically halt at resource creation boundaries—leaving data tier initialization, schema migrations, tenant record seeding, and application configuration binding to disjoint shell scripts or external orchestration pipelines:
- **Multi-Protocol Execution**: Bridges the data and orchestration layers by directly interacting with relational databases (`sql` module) and the Kubernetes API (`k8s` module) in a single script.
- **Atomic Reliability**: Uses `db.tx()` to ensure database migrations roll back cleanly on failure, preventing half-applied partial states or orphaned workloads.
- **Deterministic Teardown**: Uses `defer(lambda: db.close())` to guarantee database connection pools and file handles close cleanly on exit or termination signal.
- **Dual-Mode Delivery**: Generates multi-document Kubernetes YAML to stdout for GitOps/piping, or applies directly to an active cluster using Server-Side Apply (`k8s.apply`).

```bash
# Default run (Manifest mode with SQLite in-memory):
kite run ./12-multi-protocol-onboarding.star

# Customize tenant and service tier:
kite run ./12-multi-protocol-onboarding.star --var tenant=globex --var tier=enterprise

# Pipe manifests directly to kubectl:
kite run ./12-multi-protocol-onboarding.star --var tenant=initech | kubectl apply -f -

# Direct cluster apply (Server-Side Apply against active cluster):
kite run ./12-multi-protocol-onboarding.star --var mode=apply
```

---

### 13. Upstream Kubeadm Local Machine Setup (`kubeadm-bootstrap/`)

Automates the local infrastructure and OS preparation required before running `kubeadm init` or `kubeadm join`:
- **Configurable Machine Drivers**: Supports starting either Lima Linux VMs (macOS native) or Podman privileged systemd containers.
- **Kernel & Networking Prerequisites**: Disables swap, loads `overlay` and `br_netfilter` kernel modules, and configures sysctl IP forwarding.
- **Containerd Setup**: Installs containerd and configures `SystemdCgroup = true`.
- **Kubeadm Tooling Installation**: Configures official `pkgs.k8s.io` repository, installs `kubelet`, `kubeadm`, and `kubectl` at the requested version, and holds package updates.

```bash
cd kubeadm-bootstrap/

# Start machines and install kubeadm via Lima VMs (default):
kite run ./setup.star --var driver=lima

# Start machines and install kubeadm via Podman containers:
kite run ./setup.star --var driver=podman

# Check status across all provisioned nodes:
kite run ./setup.star --var action=status --var driver=lima

# Teardown and clean up all machines:
kite run ./setup.star --var action=destroy --var driver=lima
```


