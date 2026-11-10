#!/usr/bin/env kite

REQUIRED_KEYS = ["DB_HOST", "DB_PORT", "RATE_LIMIT_RPS", "TLS_MODE"]

def validate_keys(raw_data):
    missing = []
    for k in REQUIRED_KEYS:
        if k not in raw_data:
            missing.append(k)
    return missing

def render_config(ns, raw_data):
    return {
        "service": "payment-api",
        "namespace": ns,
        "database": {
            "host": raw_data.get("DB_HOST", "localhost"),
            "port": int(raw_data.get("DB_PORT", "5432")),
            "tls_mode": raw_data.get("TLS_MODE", "strict"),
        },
        "limits": {
            "rps": int(raw_data.get("RATE_LIMIT_RPS", "100")),
        },
    }

def main():
    ns = var_str("namespace", "init-demo")
    cm_name = var_str("configmap", "payment-api-settings")
    out_dir = var_str("out.dir", "/tmp/shared-config")

    k = k8s.config(namespace=ns, timeout="15s")

    printf("Polling ConfigMap %s/%s...\n", ns, cm_name)
    poll_res = retry.try_with_backoff(
        lambda: k.try_get("configmap", cm_name, namespace=ns),
        max_attempts=5,
        delay="300ms",
    )
    if not poll_res.ok:
        fail("dependency check failed for %s/%s: %s" % (ns, cm_name, poll_res.error))

    cm = poll_res.value.value
    raw_data = cm.get("data", {})

    missing = validate_keys(raw_data)
    if len(missing) > 0:
        fail("missing required keys %s in ConfigMap %s" % (", ".join(missing), cm_name))

    dir_res = fs.path(out_dir).try_mkdir(parents=True)
    if not dir_res.ok:
        fail("failed to create output directory %s: %s" % (out_dir, dir_res.error))

    rendered = render_config(ns, raw_data)
    payload = json.encode(rendered)
    digest = hash.text(payload).sha256()

    out_file = out_dir + "/runtime-config.json"
    write_res = fs.path(out_file).try_write_text(payload)
    if not write_res.ok:
        fail("failed to write %s: %s" % (out_file, write_res.error))

    sha_file = out_dir + "/runtime-config.sha256"
    sha_res = fs.path(sha_file).try_write_text(digest + "  runtime-config.json\n")
    if not sha_res.ok:
        fail("failed to write %s: %s" % (sha_file, sha_res.error))

    printf("Init bootstrap complete (attempts=%d):\n", poll_res.value.attempts)
    printf("  Source ConfigMap: %s/%s\n", ns, cm_name)
    printf("  Rendered Config:  %s\n", out_file)
    printf("  SHA-256 Digest:   %s\n", digest[:16] + "...")
