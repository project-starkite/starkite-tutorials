#!/usr/bin/env kite

load("./init_bootstrap.star", "init_bootstrap")

def test_validate_keys():
    valid = {
        "DB_HOST": "postgres.internal.svc.cluster.local",
        "DB_PORT": "5432",
        "RATE_LIMIT_RPS": "250",
        "TLS_MODE": "strict",
    }
    assert(len(init_bootstrap.validate_keys(valid)) == 0, "expected no missing keys")

    incomplete = {"DB_HOST": "postgres.internal.svc.cluster.local"}
    missing = init_bootstrap.validate_keys(incomplete)
    assert(len(missing) == 3, "expected 3 missing keys")
    assert("TLS_MODE" in missing, "expected TLS_MODE in missing list")

def test_render_config_types():
    raw = {
        "DB_HOST": "postgres.internal.svc.cluster.local",
        "DB_PORT": "5432",
        "RATE_LIMIT_RPS": "250",
        "TLS_MODE": "strict",
    }
    cfg = init_bootstrap.render_config("init-demo", raw)
    assert(cfg["service"] == "payment-api", "expected service payment-api")
    assert(cfg["namespace"] == "init-demo", "expected namespace init-demo")
    assert(cfg["database"]["port"] == 5432, "expected integer port 5432")
    assert(cfg["limits"]["rps"] == 250, "expected integer rps 250")

def test_json_and_digest_output():
    raw = {
        "DB_HOST": "db.init-demo.svc",
        "DB_PORT": "5432",
        "RATE_LIMIT_RPS": "500",
        "TLS_MODE": "strict",
    }
    payload = json.encode(init_bootstrap.render_config("init-demo", raw))
    digest = hash.text(payload).sha256()
    assert(len(digest) == 64, "expected 64-char sha256 hex digest")

    out_path = "/tmp/test-runtime-config.json"
    w_res = fs.path(out_path).try_write_text(payload)
    assert(w_res.ok, "expected file write to succeed")

    r_res = fs.path(out_path).try_read_text()
    assert(r_res.ok, "expected file read to succeed")
    decoded = json.decode(r_res.value)
    assert(decoded["limits"]["rps"] == 500, "expected decoded rps 500")
