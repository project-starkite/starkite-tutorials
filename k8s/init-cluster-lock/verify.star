#!/usr/bin/env kite

def main():
    app = var_str("app", "payment-api")
    ns = var_str("namespace", "init-lock-demo")
    lease_name = var_str("lease", "payment-api-migration")
    local_port = var_int("local_port", 15432)

    k = k8s.config(namespace=ns, timeout="30s")

    pg_ready = k.wait_for("deployment", "postgres", condition="Available", timeout="90s")
    if not pg_ready.ready:
        fail("postgres deployment not available: %s" % pg_ready.message)

    api_ready = k.wait_for("deployment", app, condition="Available", timeout="90s")
    if not api_ready.ready:
        fail("deployment %s not available: %s" % (app, api_ready.message))

    pods = [p for p in k.list("pods", labels="app=" + app) if p.status.phase == "Running"]
    if len(pods) != 3:
        fail("expected 3 running pods for %s, got %d" % (app, len(pods)))

    leaders = []
    followers = []
    for p in pods:
        pod_name = p.metadata.name
        init_logs = "\n".join([
            line for line in k.logs(pod_name, container="migration-bootstrap").strip().split("\n")
            if line and not line.startswith("sandbox:")
        ])
        if "role=leader" in init_logs and "status=committed" in init_logs:
            leaders.append(pod_name)
        elif "role=follower" in init_logs and "status=waiting" in init_logs and "status=verified" in init_logs:
            followers.append(pod_name)
        else:
            fail("unexpected init logs on %s:\n%s" % (pod_name, init_logs))

    if len(leaders) != 1 or len(followers) != 2:
        fail("expected 1 leader and 2 followers, got %d leader(s) (%s) and %d follower(s) (%s)" % (
            len(leaders), ", ".join(leaders), len(followers), ", ".join(followers),
        ))

    lease = k.get("lease", lease_name)
    lease_holder = lease.spec.get("holderIdentity", "")
    if lease_holder != leaders[0]:
        fail("lease holder mismatch: lease=%s leader=%s" % (lease_holder, leaders[0]))

    pg_pods = [p for p in k.list("pods", labels="app=postgres") if p.status.phase == "Running"]
    if not pg_pods:
        fail("no running postgres pod found")

    pf = k.port_forward(pg_pods[0].metadata.name, 5432, local_port=local_port)
    defer(pf.stop)

    dsn = "postgres://postgres:postgres@127.0.0.1:%d/payments?sslmode=disable" % pf.local_port
    db = sql.open("postgres", dsn)
    defer(db.close)

    mig = db.query_row("SELECT version, description, applied_by FROM schema_migrations WHERE version = $1", 1)
    if mig == None:
        fail("schema_migrations version 1 not found")
    if mig["applied_by"] != leaders[0]:
        fail("schema_migrations applied_by=%s does not match leader=%s" % (mig["applied_by"], leaders[0]))

    columns = db.query_column(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'payments'
        ORDER BY ordinal_position
        """
    )
    expected_cols = ["id", "account_id", "amount_cents", "currency", "status", "created_at"]
    if columns != expected_cols:
        fail("unexpected payments columns: got %s, want %s" % (columns, expected_cols))

    tbl = table.new(["Check", "Target", "Result"])
    tbl.add_row("Deployment Readiness", "deployment/" + app, "AVAILABLE (%d/3 pods)" % len(pods))
    tbl.add_row("Lease Coordination", "lease/" + lease_name, "1 leader, %d followers" % len(followers))
    tbl.add_row("Migration Leader", leaders[0], "COMMITTED (v%d)" % int(mig["version"]))
    tbl.add_row("Migration Ledger", "public.schema_migrations", "%s by %s" % (mig["description"], mig["applied_by"]))
    tbl.add_row("Database Schema", "public.payments", "VERIFIED (%d columns)" % len(columns))
    print(tbl.render().strip())
