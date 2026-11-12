# Distributed Database Migrations with Kubernetes Lease-Coordinated Init Containers

When a multi-replica Kubernetes `Deployment` rolls out alongside a relational schema change, every Pod starts its `initContainers` at the same time. Without distributed coordination, three replicas of a service race to create migration tables, execute `ALTER TABLE` or `CREATE TABLE` DDL statements concurrently, collide on catalog locks, or start serving HTTP traffic before a peer replica has finished committing the target schema version.

Platform teams commonly work around this race either by splitting migrations into separate pre-upgrade CI/CD `Job` pipelines—coupling cluster state to external deployment runners—or by shipping heavyweight utility images bundling `/bin/sh`, `kubectl`, `psql`, and custom shell lock loops inside every Pod. Both patterns expand image surface area and scatter coordination logic across YAML templates and shell scripts.

Starkite (`kite`) consolidates Kubernetes API coordination and transactional SQL execution inside a single static container image (`ghcr.io/project-starkite/starkite:v0.11.8`). Using the built-in `k8s`, `sql`, and `retry` modules under a default-deny sandbox, an init container contends for a `coordination.k8s.io/v1` `Lease`, runs transactional PostgreSQL migrations on the winning Pod, and holds follower replicas until the target schema version is committed.

---

## Why Uncoordinated Init Container Migrations Fail

Consider a 3-replica `payment-api` `Deployment` backed by PostgreSQL 16. When all three Pods start simultaneously, naive init containers either run DDL unconditionally on every replica or rely on fragile shell polling scripts:

```yaml
# Naive shell + psql + kubectl init container
initContainers:
  - name: db-migrate
    image: alpine/k8s:1.32.2
    command: ["/bin/sh", "-c"]
    args:
      - |
        set -eu
        until pg_isready -h postgres -U postgres -d payments; do sleep 1; done
        psql "postgres://postgres:postgres@postgres:5432/payments" -v ON_ERROR_STOP=1 <<'SQL'
          CREATE TABLE IF NOT EXISTS schema_migrations (version INT PRIMARY KEY);
          CREATE TABLE IF NOT EXISTS payments (id BIGSERIAL PRIMARY KEY, amount_cents BIGINT NOT NULL);
          INSERT INTO schema_migrations (version) VALUES (1) ON CONFLICT DO NOTHING;
        SQL
```

Running uncoordinated shell migrations across concurrent Pod replicas introduces four operational failure modes:

1. **Catalog Lock Contention & Partial Rollouts**: Concurrent `CREATE TABLE` or `ALTER TABLE` statements contend on PostgreSQL catalog and relation locks. Multi-step migrations without a single distributed leader fail mid-flight or interleave out of order.
2. **Premature Follower Readiness**: If Replica A begins a multi-statement migration while Replica B checks table existence outside a coordinated version ledger, Replica B can exit `0` and serve traffic against a half-migrated schema.
3. **Expanded Container Attack Surface**: Pulling `kubectl`, `psql`, `pg_isready`, `/bin/sh`, and shared C libraries into every Pod adds hundreds of megabytes and unnecessary binaries to a workload that only needs two network sockets.
4. **Untestable Shell Control Flow**: Lease expiration math, RFC 6902 compare-and-swap patches, and migration version checks cannot be unit-tested offline when embedded inside YAML heredocs.

Starkite replaces shell glue and external database CLIs with a sandboxed Starlark runtime that speaks both the Kubernetes `coordination.k8s.io/v1` API and the PostgreSQL wire protocol directly:

| Operational Dimension | Uncoordinated `psql` Init Container | Pre-Deploy Kubernetes `Job` | Starkite Lease-Coordinated `initContainer` |
| :--- | :--- | :--- | :--- |
| **Concurrency Control** | Database lock contention across replicas | External orchestrator must sequence `Job` before `Deployment` | Atomic `coordination.k8s.io/v1` `Lease` election per Pod |
| **Follower Synchronization** | None or ad-hoc `sleep` loops | Requires external rollout gating | Followers poll `schema_migrations` until target version commits |
| **Container Base Image** | OS userland + `/bin/sh` + `psql` + `kubectl` | Separate migration image + runner | Minimal static binary on `cgr.dev/chainguard/static` |
| **Transactional Atomicity** | Manual SQL script boundaries | Tool-dependent | Built-in `db.tx()` automatic commit/rollback |
| **Offline Unit Testing** | Requires live cluster + database | Requires live cluster + database | Built-in `kite test` runner executes in milliseconds |
| **Runtime Confinement** | Full container filesystem and env access | Full container filesystem and env access | Default-deny path, network, call, and env sandboxing |

---

## Coordination Architecture

When Kubernetes schedules the three `payment-api` Pods, each `migration-bootstrap` init container reads its Pod identity from `HOSTNAME`, contends for the `payment-api-migration` `Lease` in namespace `init-lock-demo`, and branches into either the **leader** execution path or the **follower** polling path before allowing the main `payment-api` HTTP server container to start.

```mermaid
sequenceDiagram
    participant Kubelet as Kubelet (3 Replicas)
    participant Leader as Leader Init (Pod A)
    participant Followers as Follower Inits (Pods B & C)
    participant API as Kubernetes API (Lease)
    participant PG as PostgreSQL 16 (payments)
    participant App as Main Containers (:8080)

    Kubelet->>Leader: Start kite run /scripts/init_lock_bootstrap.star
    Kubelet->>Followers: Start kite run /scripts/init_lock_bootstrap.star
    Leader->>API: try_create Lease payment-api-migration (holder=Pod A)
    API-->>Leader: 201 Created (Leader elected)
    Followers->>API: try_create Lease payment-api-migration
    API-->>Followers: 409 AlreadyExists
    Followers->>API: get Lease payment-api-migration
    API-->>Followers: holderIdentity=Pod A (status=in-progress)
    Leader->>PG: db.tx() -> CREATE schema_migrations, CREATE payments, INSERT v1
    Followers->>PG: Poll schema_migrations WHERE version >= 1
    PG-->>Leader: Transaction committed
    Leader->>API: patch Lease annotations (status=completed, version=1)
    PG-->>Followers: Row version=1 visible
    Leader-->>Kubelet: Exit 0 (role=leader status=committed)
    Followers-->>Kubelet: Exit 0 (role=follower status=verified)
    Kubelet->>App: Start all 3 payment-api containers on :8080
```

Inside the init container, `kite run` starts in `deny-all` mode and receives only the capabilities required for Lease coordination and PostgreSQL connectivity:

- `--sandbox-path-read=/scripts`: Permits reading the mounted `init_lock_bootstrap.star` script from the `ConfigMap` volume.
- `--sandbox-path-read=/var/run/secrets/kubernetes.io/serviceaccount`: Permits `k8s.config()` to read the Pod's ServiceAccount token and cluster CA bundle.
- `--sandbox-net-allow`: Permits outbound connections to the Kubernetes API server and `postgres.init-lock-demo.svc.cluster.local:5432`.
- `--env=HOSTNAME`, `--env=KUBERNETES_SERVICE_HOST`, `--env=KUBERNETES_SERVICE_PORT`: Forwards the Pod name for Lease holder identity and the API server discovery endpoints while scrubbing all other ambient environment variables.

---

## Companion Files

All scripts and manifests for this tutorial reside in [`k8s/init-cluster-lock/`](./):

| File | Purpose |
| :--- | :--- |
| [`init_lock_bootstrap.star`](./init_lock_bootstrap.star) | Sandboxed init container script implementing Kubernetes `Lease` acquisition, transactional PostgreSQL DDL migration, and follower version polling. |
| [`init_lock_bootstrap_test.star`](./init_lock_bootstrap_test.star) | Offline unit test suite validating DSN construction, `Lease` state evaluation, expiration takeover, and version ledger checks via `kite test`. |
| [`manifest.star`](./manifest.star) | Programmatic manifest generator producing the `Namespace`, RBAC `Role`/`RoleBinding`, script `ConfigMap`, PostgreSQL 16 workload, and 3-replica `payment-api` `Deployment`. |
| [`manifest.yaml`](./manifest.yaml) | Pre-rendered multi-document Kubernetes YAML manifest ready for `kubectl apply -f ./manifest.yaml`. |
| [`verify.star`](./verify.star) | Live cluster verifier asserting Deployment readiness, 1-leader / 2-follower log invariants, `Lease` metadata, and PostgreSQL table schema via `k.port_forward` and `sql.open`. |

---

## Step 1: Implement the Lease-Coordinated Migration Script

Structure the init script so pure coordination and schema-checking decisions are isolated from network I/O. Separating `build_lease`, `evaluate_lease`, and `has_migration_version` from live `k8s` and `sql` calls keeps the state machine small and directly testable offline.

Examine [`init_lock_bootstrap.star`](./init_lock_bootstrap.star):

```python
#!/usr/bin/env kite

LEASE_NAME = "payment-api-migration"
TARGET_VERSION = 1
MICRO_LAYOUT = "2006-01-02T15:04:05.000000Z"

SCHEMA_MIGRATIONS_DDL = """
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    description TEXT NOT NULL,
    applied_by TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
"""

PAYMENTS_DDL = """
CREATE TABLE IF NOT EXISTS payments (
    id BIGSERIAL PRIMARY KEY,
    account_id TEXT NOT NULL,
    amount_cents BIGINT NOT NULL CHECK (amount_cents >= 0),
    currency CHAR(3) NOT NULL DEFAULT 'USD',
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
"""

def build_dsn(host, port, user, password, dbname):
    return "postgres://%s:%s@%s:%d/%s?sslmode=disable" % (user, password, host, int(port), dbname)

def build_lease(ns, name, holder, duration_sec, now_micro):
    return {
        "apiVersion": "coordination.k8s.io/v1",
        "kind": "Lease",
        "metadata": {
            "name": name,
            "namespace": ns,
            "annotations": {
                "migration.starkite.io/status": "in-progress",
            },
        },
        "spec": {
            "holderIdentity": holder,
            "leaseDurationSeconds": duration_sec,
            "acquireTime": now_micro,
            "renewTime": now_micro,
            "leaseTransitions": 0,
        },
    }

def evaluate_lease(lease, candidate, now, target_version=TARGET_VERSION):
    meta = lease.get("metadata") or {}
    annotations = meta.get("annotations") or {}
    spec = lease.get("spec") or {}

    holder = spec.get("holderIdentity") or ""
    transitions = int(spec.get("leaseTransitions") or 0)
    ver_raw = annotations.get("migration.starkite.io/version", "0")
    completed_version = int(ver_raw) if ver_raw else 0

    if completed_version >= target_version:
        return {
            "can_acquire": False,
            "holder": holder,
            "completed_version": completed_version,
            "transitions": transitions,
            "reason": "completed",
        }

    if holder == candidate:
        return {
            "can_acquire": True,
            "holder": holder,
            "completed_version": completed_version,
            "transitions": transitions,
            "reason": "already_holder",
        }

    if holder == "":
        return {
            "can_acquire": True,
            "holder": "",
            "completed_version": completed_version,
            "transitions": transitions,
            "reason": "unclaimed",
        }

    renew_str = spec.get("renewTime") or spec.get("acquireTime") or ""
    duration_sec = int(spec.get("leaseDurationSeconds") or 60)
    if renew_str:
        expires_at = time.parse(renew_str).add("%ds" % duration_sec)
        if now >= expires_at:
            return {
                "can_acquire": True,
                "holder": holder,
                "completed_version": completed_version,
                "transitions": transitions + 1,
                "reason": "expired",
            }

    return {
        "can_acquire": False,
        "holder": holder,
        "completed_version": completed_version,
        "transitions": transitions,
        "reason": "held_by_peer",
    }

def has_migration_version(rows, target_version=TARGET_VERSION):
    for r in rows:
        if int(r.get("version", 0)) >= target_version:
            return True
    return False

def claim_lease(k, ns, lease_name, holder, duration_sec):
    now_val = time.now().utc
    now_micro = now_val.string(MICRO_LAYOUT)

    created = k.try_create(build_lease(ns, lease_name, holder, duration_sec, now_micro))
    if created.ok:
        return {"acquired": True, "holder": holder}

    lease = k.get("lease", lease_name)
    decision = evaluate_lease(lease, holder, now_val)
    if not decision["can_acquire"]:
        return {"acquired": False, "holder": decision["holder"]}

    cas_ops = json.encode([
        {"op": "test", "path": "/metadata/resourceVersion", "value": lease["metadata"]["resourceVersion"]},
        {"op": "replace", "path": "/spec/holderIdentity", "value": holder},
        {"op": "replace", "path": "/spec/acquireTime", "value": now_micro},
        {"op": "replace", "path": "/spec/renewTime", "value": now_micro},
        {"op": "replace", "path": "/spec/leaseTransitions", "value": decision["transitions"]},
    ])
    patched = k.try_patch("lease", lease_name, cas_ops, type="json")
    if patched.ok:
        return {"acquired": True, "holder": holder}

    latest = k.get("lease", lease_name)
    return {"acquired": False, "holder": (latest.get("spec") or {}).get("holderIdentity") or "unknown"}

def open_postgres(dsn, max_attempts=60, delay="1s"):
    res = retry.do(lambda: sql.open("postgres", dsn), max_attempts=max_attempts, delay=delay)
    if not res.ok:
        fail("postgres connection failed: %s" % res.error)
    return res.value

def run_leader_migration(db, holder):
    def migrate(tx):
        tx.exec(SCHEMA_MIGRATIONS_DDL)
        tx.exec(PAYMENTS_DDL)
        tx.exec(
            """
            INSERT INTO schema_migrations (version, description, applied_by)
            VALUES ($1, $2, $3)
            ON CONFLICT (version) DO NOTHING
            """,
            TARGET_VERSION,
            "create_payments_table",
            holder,
        )

    db.tx(migrate)

def complete_lease(k, lease_name, holder):
    now_micro = time.now().utc.string(MICRO_LAYOUT)
    k.patch("lease", lease_name, {
        "metadata": {
            "annotations": {
                "migration.starkite.io/status": "completed",
                "migration.starkite.io/version": str(TARGET_VERSION),
                "migration.starkite.io/leader": holder,
            },
        },
        "spec": {
            "holderIdentity": holder,
            "renewTime": now_micro,
        },
    })

def check_migration_applied(db, target_version):
    queried = db.try_query("SELECT version FROM schema_migrations WHERE version >= $1", target_version)
    if not queried.ok:
        return False
    return has_migration_version(queried.value, target_version)

def wait_for_migration(db, target_version=TARGET_VERSION, max_polls=60, delay="1s"):
    res = retry.do(
        lambda: check_migration_applied(db, target_version),
        max_attempts=max_polls,
        delay=delay,
    )
    if not res.ok:
        fail("timed out waiting for schema migration v%d: %s" % (target_version, res.error))
```

Each function addresses a specific distributed coordination requirement:

- **Atomic Lease Creation (`claim_lease`)**: Calling `k.try_create(...)` submits `Lease/payment-api-migration` with `MicroTime` timestamps (`2006-01-02T15:04:05.000000Z`). Kubernetes guarantees that at most one concurrent Pod receives `created.ok == True`; the remaining replicas receive `AlreadyExists` and inspect the active holder.
- **Optimistic-Concurrency Takeover (`evaluate_lease` & RFC 6902 `test`)**: If a previous leader crashed before recording `migration.starkite.io/version: "1"` and `leaseDurationSeconds` has elapsed, `claim_lease` issues a JSON Patch (`type="json"`) gated on `/metadata/resourceVersion` so only one standby candidate can take over leadership.
- **Transactional DDL & Version Recording (`run_leader_migration`)**: PostgreSQL executes DDL statements transactionally. Running `CREATE TABLE IF NOT EXISTS schema_migrations`, `CREATE TABLE IF NOT EXISTS payments`, and `INSERT INTO schema_migrations` inside `db.tx(migrate)` guarantees that followers never observe partial schema state; any error rolls back all three statements automatically.
- **Resilient Readiness & Follower Polling (`open_postgres` & `wait_for_migration`)**: `retry.do(...)` absorbs both initial PostgreSQL container startup latency and the window before `schema_migrations` exists (`db.try_query` returns `queried.ok == False`, which maps to `False` and triggers the next poll).

---

## Step 2: Validate and Unit-Test Offline

Before touching a Kubernetes cluster, run static lint analysis and execute the unit tests for Lease state transitions and migration version checks.

Examine [`init_lock_bootstrap_test.star`](./init_lock_bootstrap_test.star):

```python
#!/usr/bin/env kite

load("./init_lock_bootstrap.star", "init_lock_bootstrap")

def test_build_dsn_and_lease():
    dsn = init_lock_bootstrap.build_dsn("postgres.init-lock-demo.svc.cluster.local", "5432", "postgres", "postgres", "payments")
    assert_equal(dsn, "postgres://postgres:postgres@postgres.init-lock-demo.svc.cluster.local:5432/payments?sslmode=disable")

    lease = init_lock_bootstrap.build_lease(
        "init-lock-demo",
        "payment-api-migration",
        "payment-api-abc-1",
        60,
        "2026-11-12T01:00:00.000000Z",
    )
    assert_equal(lease["apiVersion"], "coordination.k8s.io/v1")
    assert_equal(lease["kind"], "Lease")
    assert_equal(lease["spec"]["holderIdentity"], "payment-api-abc-1")
    assert_equal(lease["spec"]["leaseDurationSeconds"], 60)

def test_evaluate_lease_active_peer_and_expiry():
    lease = init_lock_bootstrap.build_lease(
        "init-lock-demo",
        "payment-api-migration",
        "payment-api-pod-1",
        30,
        "2026-11-12T01:00:00.000000Z",
    )

    active_now = time.parse("2026-11-12T01:00:10Z")
    held = init_lock_bootstrap.evaluate_lease(lease, "payment-api-pod-2", active_now)
    assert_false(held["can_acquire"])
    assert_equal(held["holder"], "payment-api-pod-1")
    assert_equal(held["reason"], "held_by_peer")

    expired_now = time.parse("2026-11-12T01:00:45Z")
    expired = init_lock_bootstrap.evaluate_lease(lease, "payment-api-pod-2", expired_now)
    assert_true(expired["can_acquire"])
    assert_equal(expired["transitions"], 1)
    assert_equal(expired["reason"], "expired")

def test_evaluate_lease_completed_blocks_reelection():
    lease = init_lock_bootstrap.build_lease(
        "init-lock-demo",
        "payment-api-migration",
        "payment-api-pod-1",
        30,
        "2026-11-12T01:00:00.000000Z",
    )
    lease["metadata"]["annotations"]["migration.starkite.io/version"] = "1"
    lease["metadata"]["annotations"]["migration.starkite.io/status"] = "completed"

    later = time.parse("2026-11-12T02:00:00Z")
    done = init_lock_bootstrap.evaluate_lease(lease, "payment-api-pod-2", later)
    assert_false(done["can_acquire"])
    assert_equal(done["completed_version"], 1)
    assert_equal(done["reason"], "completed")

def test_has_migration_version():
    assert_false(init_lock_bootstrap.has_migration_version([], 1))
    assert_false(init_lock_bootstrap.has_migration_version([{"version": 0}], 1))
    assert_true(init_lock_bootstrap.has_migration_version([{"version": 1}], 1))
    assert_true(init_lock_bootstrap.has_migration_version([{"version": 1}, {"version": 2}], 2))
```

Run `kite validate` and `kite test` from `k8s/init-cluster-lock`:

```bash
cd /home/alice/projects/starkite-tutorials/k8s/init-cluster-lock
kite validate --lint --json *.star
kite test ./init_lock_bootstrap_test.star --sandbox-path-read=.
```

```text
# (host-specific values differ)
Found 1 test file(s)
============================================================
Tests: 4 passed, 0 failed, 4 total
Time:  8ms
============================================================
```

The test suite verifies active holder rejection (`held_by_peer`), expired Lease takeover with incremented `leaseTransitions`, post-completion re-election suppression (`completed`), and `schema_migrations` version matching—all under `--sandbox-path-read=.` with no network or database access.

---

## Step 3: Generate the Kubernetes Stack and Deploy

[`manifest.star`](./manifest.star) uses `k8s.obj.*` constructors to assemble the entire `init-lock-demo` environment:

- **`Namespace` & RBAC (`payment-api-sa`)**: Scopes a least-privilege `Role` granting `["get", "list", "create", "update", "patch"]` exclusively on `coordination.k8s.io` `leases` within `init-lock-demo`.
- **Script `ConfigMap` (`payment-api-migration-script`)**: Embeds `init_lock_bootstrap.star` directly from disk via `fs.read_text(script_path)` and mounts it read-only at `/scripts`.
- **PostgreSQL 16 (`postgres` `Deployment` & `Service`)**: Runs `postgres:16-alpine` initialized with database `payments` and a `pg_isready` readiness probe on port `5432`.
- **3-Replica Application (`payment-api` `Deployment`)**: Runs `migration-bootstrap` as a sandboxed init container before starting the `payment-api` container on HTTP port `8080`, which queries `schema_migrations` and serves service readiness JSON.

Render [`manifest.yaml`](./manifest.yaml) and apply it to your cluster:

```bash
kite run ./manifest.star --sandbox-path-read=. > ./manifest.yaml
kubectl apply -f ./manifest.yaml
```

```text
# (host-specific values differ)
namespace/init-lock-demo created
serviceaccount/payment-api-sa created
role.rbac.authorization.k8s.io/payment-api-lease-coordinator created
rolebinding.rbac.authorization.k8s.io/payment-api-lease-coordinator-binding created
configmap/payment-api-migration-script created
deployment.apps/postgres created
service/postgres created
deployment.apps/payment-api created
```

Inspect the Pods, the `Lease` resource, and the `migration-bootstrap` init container logs across all three replicas:

```bash
kubectl -n init-lock-demo get pods,lease
kubectl -n init-lock-demo logs deployment/payment-api -c migration-bootstrap --prefix=true --all-pods=true
```

```text
# (host-specific values differ)
NAME                               READY   STATUS    RESTARTS   AGE
pod/payment-api-696cf9ddd8-cjz6r   1/1     Running   0          44s
pod/payment-api-696cf9ddd8-pcf94   1/1     Running   0          44s
pod/payment-api-696cf9ddd8-q6c9j   1/1     Running   0          44s
pod/postgres-54bf69f6bb-kf2ms      1/1     Running   0          44s

NAME                                              HOLDER                         AGE
lease.coordination.k8s.io/payment-api-migration   payment-api-696cf9ddd8-q6c9j   42s

[pod/payment-api-696cf9ddd8-pcf94/migration-bootstrap] role=follower pod=payment-api-696cf9ddd8-pcf94 leader=payment-api-696cf9ddd8-q6c9j status=waiting
[pod/payment-api-696cf9ddd8-pcf94/migration-bootstrap] role=follower pod=payment-api-696cf9ddd8-pcf94 migration_version=1 status=verified
[pod/payment-api-696cf9ddd8-q6c9j/migration-bootstrap] role=leader pod=payment-api-696cf9ddd8-q6c9j lease=payment-api-migration status=acquired
[pod/payment-api-696cf9ddd8-q6c9j/migration-bootstrap] role=leader pod=payment-api-696cf9ddd8-q6c9j migration_version=1 status=committed
[pod/payment-api-696cf9ddd8-cjz6r/migration-bootstrap] role=follower pod=payment-api-696cf9ddd8-cjz6r leader=payment-api-696cf9ddd8-q6c9j status=waiting
[pod/payment-api-696cf9ddd8-cjz6r/migration-bootstrap] role=follower pod=payment-api-696cf9ddd8-cjz6r migration_version=1 status=verified
```

Pod `payment-api-696cf9ddd8-q6c9j` won the `Lease`, executed the transactional DDL against PostgreSQL, and annotated `payment-api-migration` as completed, while `pcf94` and `cjz6r` waited as followers until version `1` appeared in `schema_migrations`.

---

## Step 4: Verify Cluster State and Database Schema

[`verify.star`](./verify.star) automates end-to-end validation across both the Kubernetes API and PostgreSQL:

1. Waits for `deployment/postgres` and `deployment/payment-api` to report `Available`.
2. Reads `migration-bootstrap` init container logs from all three `payment-api` Pods and asserts that **1** Pod ran as migration leader (`role=leader ... status=committed`) and **2** Pods waited as followers (`role=follower ... status=waiting` and `status=verified`).
3. Confirms `Lease/payment-api-migration` `holderIdentity` matches the leader Pod.
4. Opens an ephemeral background port-forward (`k.port_forward`) to `postgres:5432`, connects via `sql.open("postgres", dsn)`, verifies version `1` and `applied_by` in `public.schema_migrations`, and inspects `information_schema.columns` on `public.payments`.

Execute [`verify.star`](./verify.star):

```bash
kite run ./verify.star \
  --sandbox-path-read=. \
  --sandbox-path-read=$HOME/.kube \
  --sandbox-net-allow \
  --env=HOME
```

```text
# (host-specific values differ)
Check                | Target                       | Result                                               
---------------------+------------------------------+------------------------------------------------------
Deployment Readiness | deployment/payment-api       | AVAILABLE (3/3 pods)                                 
Lease Coordination   | lease/payment-api-migration  | 1 leader, 2 followers                                
Migration Leader     | payment-api-696cf9ddd8-q6c9j | COMMITTED (v1)                                       
Migration Ledger     | public.schema_migrations     | create_payments_table by payment-api-696cf9ddd8-q6c9j
Database Schema      | public.payments              | VERIFIED (6 columns)
```

---

## Cleanup

Delete the `init-lock-demo` namespace when finished to remove all Pods, Services, RBAC bindings, ConfigMaps, and Leases:

```bash
kubectl delete namespace init-lock-demo
```
