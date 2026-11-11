#!/usr/bin/env kite

def main():
    ns = var_str("namespace", "init-demo")
    out = fs.path(var_str("out.dir", "/work/shared"))

    k = k8s.config(namespace=ns)
    poll = retry.with_backoff(
        lambda: k.try_get("configmap", "payment-api-settings"),
        max_attempts=5,
        delay="300ms",
    )
    if not poll.ok:
        fail("dependency check failed for %s/payment-api-settings: %s" % (ns, poll.error))

    data = poll.value.get("data", {})
    missing = [k for k in ["DB_HOST", "DB_PORT", "RATE_LIMIT_RPS", "TLS_MODE"] if not data.get(k)]
    if missing:
        fail("missing required keys %s in ConfigMap payment-api-settings" % ", ".join(missing))

    payload = json.encode({
        "service": "payment-api",
        "namespace": ns,
        "database": {
            "host": data["DB_HOST"],
            "port": int(data["DB_PORT"]),
            "tls_mode": data["TLS_MODE"],
        },
        "limits": {
            "rps": int(data["RATE_LIMIT_RPS"]),
        },
    })

    out.mkdir(parents=True)
    (out / "runtime-config.json").write_text(payload)
    (out / "runtime-config.sha256").write_text(hash.text(payload).sha256() + "  runtime-config.json\n")
