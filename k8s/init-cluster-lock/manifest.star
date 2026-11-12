#!/usr/bin/env kite

def build_stack(
    app="payment-api",
    ns="init-lock-demo",
    kite_image="ghcr.io/project-starkite/starkite:v0.11.8",
    pg_image="postgres:16-alpine",
):
    namespace = k8s.obj.namespace(name=ns)

    sa = k8s.obj.service_account(name=app + "-sa", namespace=ns)
    role_name = app + "-lease-coordinator"
    role = k8s.obj.role(
        name=role_name,
        namespace=ns,
        rules=[
            k8s.obj.policy_rule(
                api_groups=["coordination.k8s.io"],
                resources=["leases"],
                verbs=["get", "list", "create", "update", "patch"],
            ),
        ],
    )
    rb = k8s.obj.role_binding(
        name=role_name + "-binding",
        namespace=ns,
        role_ref={"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": role_name},
        subjects=[k8s.obj.subject(kind="ServiceAccount", name=sa, namespace=ns)],
    )

    script_path = var_str("script", "./init_lock_bootstrap.star")
    script_cm = k8s.obj.config_map(
        name=app + "-migration-script",
        namespace=ns,
        data={"init_lock_bootstrap.star": fs.read_text(script_path)},
    )

    pg_dep = k8s.obj.deployment(
        name="postgres",
        namespace=ns,
        labels={"app": "postgres"},
        replicas=1,
        containers=[
            k8s.obj.container(
                name="postgres",
                image=pg_image,
                ports=[k8s.obj.container_port(container_port=5432, name="postgres")],
                env=[
                    k8s.obj.env_var(name="POSTGRES_DB", value="payments"),
                    k8s.obj.env_var(name="POSTGRES_USER", value="postgres"),
                    k8s.obj.env_var(name="POSTGRES_PASSWORD", value="postgres"),
                ],
                readiness_probe=k8s.obj.probe(
                    exec={"command": ["pg_isready", "-U", "postgres", "-d", "payments"]},
                    initial_delay_seconds=2,
                    period_seconds=3,
                ),
            ),
        ],
    )

    pg_svc = k8s.obj.service(
        name="postgres",
        namespace=ns,
        labels={"app": "postgres"},
        selector={"app": "postgres"},
        ports=[k8s.obj.service_port(port=5432, target_port=5432, name="postgres")],
    )

    init_container = k8s.obj.container(
        name="migration-bootstrap",
        image=kite_image,
        args=[
            "run",
            "/scripts/init_lock_bootstrap.star",
            "--sandbox-path-read=/scripts",
            "--sandbox-path-read=/var/run/secrets/kubernetes.io/serviceaccount",
            "--sandbox-net-allow",
            "--env=HOSTNAME",
            "--env=KUBERNETES_SERVICE_HOST",
            "--env=KUBERNETES_SERVICE_PORT",
        ],
        volume_mounts=[
            k8s.obj.volume_mount(name="migration-script", mount_path="/scripts", read_only=True),
        ],
    )

    dsn = "postgres://postgres:postgres@postgres.%s.svc.cluster.local:5432/payments?sslmode=disable" % ns
    web_script = """def main():
    db = sql.open("postgres", %r)
    row = db.query_row("SELECT MAX(version) AS version FROM schema_migrations")
    payload = json.encode({
        "service": %r,
        "pod": env("HOSTNAME"),
        "schema_version": int(row["version"]),
        "status": "ready",
    })
    print(payload)
    http.serve({"GET /": lambda req: {"status": 200, "headers": {"Content-Type": "application/json"}, "body": payload}}, port=8080)
""" % (dsn, app)

    app_container = k8s.obj.container(
        name=app,
        image=kite_image,
        command=["kite", "eval"],
        args=[
            web_script,
            "--sandbox-net-allow",
            "--sandbox-call-allow=os.env",
            "--env=HOSTNAME",
        ],
        ports=[k8s.obj.container_port(container_port=8080, name="http")],
        readiness_probe=k8s.obj.probe(
            http_get={"path": "/", "port": 8080},
            initial_delay_seconds=1,
            period_seconds=3,
        ),
    )

    api_dep = k8s.obj.deployment(
        name=app,
        namespace=ns,
        labels={"app": app},
        replicas=3,
        service_account=sa,
        init_containers=[init_container],
        containers=[app_container],
        volumes=[
            k8s.obj.volume(name="migration-script", config_map=script_cm),
        ],
    )

    return [namespace, sa, role, rb, script_cm, pg_dep, pg_svc, api_dep]

def main():
    stack = build_stack(
        app=var_str("app", "payment-api"),
        ns=var_str("namespace", "init-lock-demo"),
    )
    print(k8s.yaml(stack))
