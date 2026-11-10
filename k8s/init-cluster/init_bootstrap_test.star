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

    missing = init_bootstrap.validate_keys({"DB_HOST": SAMPLE_DATA["DB_HOST"], "TLS_MODE": ""})
    assert_equal(len(missing), 3)
    assert_contains(missing, "TLS_MODE")

def test_render_config_types():
    cfg = init_bootstrap.render_config("init-demo", SAMPLE_DATA)
    assert_equal(cfg["service"], "payment-api")
    assert_equal(cfg["namespace"], "init-demo")
    assert_equal(cfg["database"]["port"], 5432)
    assert_equal(cfg["limits"]["rps"], 250)

def test_json_and_digest_output():
    payload = json.encode(init_bootstrap.render_config("init-demo", SAMPLE_DATA))
    digest = hash.text(payload).sha256()
    assert_equal(len(digest), 64)

    out_dir = fs.path("/tmp/kite-init-test")
    out_dir.mkdir(parents=True)
    out_file = out_dir / "runtime-config.json"
    out_file.write_text(payload)
    assert_equal(hash.file(out_file.string).sha256(), digest)
    assert_equal(json.file(out_file.string).decode()["limits"]["rps"], 250)
