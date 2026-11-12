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

def main():
    ns = var_str("namespace", "init-lock-demo")
    lease_name = var_str("lease", LEASE_NAME)
    duration_sec = var_int("lease.duration", 60)

    pod_name = env("HOSTNAME")
    if not pod_name:
        pod_name = var_str("holder", "")
    if not pod_name:
        fail("HOSTNAME environment variable is required for lease identity")

    dsn = build_dsn(
        host=var_str("db.host", "postgres.%s.svc.cluster.local" % ns),
        port=var_int("db.port", 5432),
        user=var_str("db.user", "postgres"),
        password=var_str("db.password", "postgres"),
        dbname=var_str("db.name", "payments"),
    )

    k = k8s.config(namespace=ns)
    claim = claim_lease(k, ns, lease_name, pod_name, duration_sec)
    db = open_postgres(dsn)
    defer(db.close)

    if claim["acquired"]:
        printf("role=leader pod=%s lease=%s status=acquired\n", pod_name, lease_name)
        run_leader_migration(db, pod_name)
        complete_lease(k, lease_name, pod_name)
        printf("role=leader pod=%s migration_version=%d status=committed\n", pod_name, TARGET_VERSION)
    else:
        printf("role=follower pod=%s leader=%s status=waiting\n", pod_name, claim["holder"])
        wait_for_migration(db, TARGET_VERSION)
        printf("role=follower pod=%s migration_version=%d status=verified\n", pod_name, TARGET_VERSION)
