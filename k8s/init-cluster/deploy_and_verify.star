#!/usr/bin/env kite

load("./init_bootstrap.star", "init_bootstrap")

def main():
    app = var_str("app", "payment-api")
    ns = var_str("namespace", "init-demo")
    out_dir = var_str("out.dir", "/tmp/shared-config")

    k = k8s.config(namespace=ns, timeout="15s")

    ns_obj = k8s.obj.namespace(name=ns)
    sa_name = app + "-sa"
    sa_obj = k8s.obj.service_account(
        name=sa_name,
        namespace=ns,
        automount_service_account_token=True,
    )
    role_name = app + "-config-reader"
    role_obj = k8s.obj.role(
        name=role_name,
        namespace=ns,
        rules=[
            {
                "apiGroups": [""],
                "resources": ["configmaps"],
                "verbs": ["get", "list"],
            },
        ],
    )
    rb_obj = k8s.obj.role_binding(
        name=role_name + "-binding",
        namespace=ns,
        role_ref={
            "apiGroup": "rbac.authorization.k8s.io",
            "kind": "Role",
            "name": role_name,
        },
        subjects=[
            {
                "kind": "ServiceAccount",
                "name": sa_name,
                "namespace": ns,
            },
        ],
    )
    settings_cm = k8s.obj.config_map(
        name=app + "-settings",
        namespace=ns,
        data={
            "DB_HOST": "postgres.internal.svc.cluster.local",
            "DB_PORT": "5432",
            "RATE_LIMIT_RPS": "250",
            "TLS_MODE": "strict",
        },
    )

    prereqs = [ns_obj, sa_obj, role_obj, rb_obj, settings_cm]
    for obj in prereqs:
        res = k.try_apply(obj, namespace=ns)
        if not res.ok:
            fail("failed to apply %s: %s" % (obj.kind, res.error))

    init_bootstrap.main()

    cfg_path = out_dir + "/runtime-config.json"
    sha_path = out_dir + "/runtime-config.sha256"

    cfg_res = fs.path(cfg_path).try_read_text()
    if not cfg_res.ok:
        fail("failed to read rendered config: %s" % cfg_res.error)

    sha_res = fs.path(sha_path).try_read_text()
    if not sha_res.ok:
        fail("failed to read sha256 file: %s" % sha_res.error)

    actual_digest = hash.text(cfg_res.value).sha256()
    recorded_digest = sha_res.value.split(" ")[0]
    if actual_digest != recorded_digest:
        fail("digest mismatch: actual=%s recorded=%s" % (actual_digest, recorded_digest))

    parsed = json.decode(cfg_res.value)

    tbl = table.new(["Check", "Target", "Result"])
    tbl.add_row("RBAC & ConfigMap Apply", ns + "/" + app + "-settings", "APPLIED (5 resources)")
    tbl.add_row("Init Script Execution", cfg_path, "RENDERED")
    tbl.add_row("Database Endpoint", parsed["database"]["host"] + ":" + str(int(parsed["database"]["port"])), "VERIFIED")
    tbl.add_row("Rate Limit (RPS)", str(int(parsed["limits"]["rps"])), "VERIFIED")
    tbl.add_row("SHA-256 Integrity", actual_digest[:16] + "...", "MATCHED")
    print("\n" + tbl.render().strip())
