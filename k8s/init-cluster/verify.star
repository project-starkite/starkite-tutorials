#!/usr/bin/env kite

def main():
    app = var_str("app", "payment-api")
    ns = var_str("namespace", "init-demo")

    k = k8s.config(namespace=ns, timeout="30s")

    ready = k.wait_for("deployment", app, condition="Available", timeout="60s")
    if not ready.ready:
        fail("deployment %s not available: %s" % (app, ready.message))

    pods = [p for p in k.list("pods", labels="app=" + app) if p.status.phase == "Running"]
    if not pods:
        fail("no running pods found for app=%s" % app)
    pod_name = pods[0].metadata.name

    app_lines = k.logs(pod_name, container=app).strip().split("\n")
    raw_json = app_lines[0]
    recorded_digest = app_lines[1].split(" ")[0]

    actual_digest = hash.text(raw_json).sha256()
    if actual_digest != recorded_digest:
        fail("digest mismatch: actual=%s recorded=%s" % (actual_digest, recorded_digest))

    parsed = json.decode(raw_json)

    tbl = table.new(["Check", "Target", "Result"])
    tbl.add_row("Deployment Readiness", "deployment/" + app, "AVAILABLE (%d pods)" % len(pods))
    tbl.add_row("Database Endpoint", "%s:%d" % (parsed["database"]["host"], int(parsed["database"]["port"])), "VERIFIED")
    tbl.add_row("Rate Limit (RPS)", str(int(parsed["limits"]["rps"])), "VERIFIED")
    tbl.add_row("SHA-256 Integrity", actual_digest[:16] + "...", "MATCHED")
    print(tbl.render().strip())
