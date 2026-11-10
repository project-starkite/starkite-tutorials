#!/usr/bin/env kite

REQUIRED_KEYS = ["DB_HOST", "DB_PORT", "RATE_LIMIT_RPS", "TLS_MODE"]

def validate_keys(raw_data):
    return [k for k in REQUIRED_KEYS if not raw_data.get(k)]

def render_config(ns, raw_data):
    return {
        "service": "payment-api",
        "namespace": ns,
        "database": {
            "host": raw_data["DB_HOST"],
            "port": int(raw_data["DB_PORT"]),
            "tls_mode": raw_data["TLS_MODE"],
        },
        "limits": {
            "rps": int(raw_data["RATE_LIMIT_RPS"]),
        },
    }

def main():
    ns = var_str("namespace", "init-demo")
    cm_name = var_str("configmap", "payment-api-settings")
    out = fs.path(var_str("out.dir", "/tmp/shared-config"))

    k = k8s.config(namespace=ns, timeout="15s")

    printf("Polling ConfigMap %s/%s...\n", ns, cm_name)
    poll = retry.with_backoff(
        lambda: k.try_get("configmap", cm_name),
        max_attempts=5,
        delay="300ms",
    )
    if not poll.ok:
        fail("dependency check failed for %s/%s: %s" % (ns, cm_name, poll.error))

    raw_data = poll.value.get("data", {})
    missing = validate_keys(raw_data)
    if missing:
        fail("missing required keys %s in ConfigMap %s" % (", ".join(missing), cm_name))

    out.mkdir(parents=True)
    payload = json.encode(render_config(ns, raw_data))
    digest = hash.text(payload).sha256()

    cfg_file = out / "runtime-config.json"
    sha_file = out / "runtime-config.sha256"
    cfg_file.write_text(payload)
    sha_file.write_text(digest + "  runtime-config.json\n")

    printf("Init bootstrap complete (attempts=%d):\n", poll.attempts)
    printf("  Source ConfigMap: %s/%s\n", ns, cm_name)
    printf("  Rendered Config:  %s\n", cfg_file.string)
    printf("  SHA-256 Digest:   %s...\n", digest[:16])
