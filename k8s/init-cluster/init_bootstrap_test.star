#!/usr/bin/env kite

load("./init_bootstrap.star", "init_bootstrap")

SAMPLE_DATA = {
    "DB_HOST": "postgres.internal.svc.cluster.local",
    "DB_PORT": "5432",
    "RATE_LIMIT_RPS": "250",
    "TLS_MODE": "strict",
}

def test_validate_keys():
    assert_equal(init_bootstrap.validate_keys(SAMPLE_DATA), [])
    missing = init_bootstrap.validate_keys({"DB_HOST": "db", "TLS_MODE": ""})
    assert_equal(len(missing), 3)

def test_render_config():
    cfg = init_bootstrap.render_config("init-demo", SAMPLE_DATA)
    assert_equal(cfg["service"], "payment-api")
    assert_equal(cfg["database"]["port"], 5432)
    assert_equal(cfg["limits"]["rps"], 250)
