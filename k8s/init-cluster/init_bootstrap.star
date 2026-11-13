#!/usr/bin/env kite

REQUIRED_KEYS = ["DB_HOST", "DB_PORT", "RATE_LIMIT_RPS", "TLS_MODE"]

def validate_keys(data):
    return [k for k in REQUIRED_KEYS if not data.get(k)]

def render_config(ns, data):
    return {
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
    }

def main():
    ns = "init-demo"
    out = fs.path("/etc/payment-api")

    k = k8s.config(namespace=ns)
    cm = k.get("configmap", "payment-api-settings")

    data = cm.get("data", {})
    missing = validate_keys(data)
    if missing:
        fail("missing required keys: %s" % ", ".join(missing))

    payload = json.encode(render_config(ns, data))
    out.mkdir(parents=True)
    (out / "runtime-config.json").write_text(payload)
    (out / "runtime-config.sha256").write_text(hash.text(payload).sha256() + "  runtime-config.json\n")
