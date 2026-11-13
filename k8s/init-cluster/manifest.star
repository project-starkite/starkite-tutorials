#!/usr/bin/env kite

def main():
    app = var_str("app", "payment-api")
    ns = var_str("namespace", "init-demo")
    kite_image = "ghcr.io/project-starkite/starkite:v0.11.8"

    sa = k8s.obj.service_account(name=app + "-sa", namespace=ns)
    role_name = app + "-config-reader"
    role = k8s.obj.role(
        name=role_name,
        namespace=ns,
        rules=[k8s.obj.policy_rule(api_groups=[""], resources=["configmaps"], verbs=["get", "list"])],
    )
    rb = k8s.obj.role_binding(
        name=role_name + "-binding",
        namespace=ns,
        role_ref={"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": role_name},
        subjects=[k8s.obj.subject(kind="ServiceAccount", name=sa, namespace=ns)],
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
    script_path = var_str("script", "./init_bootstrap.star")
    server_script_path = var_str("server_script", "./server.star")

    init_container = k8s.obj.container(
        name="config-bootstrap",
        image=kite_image,
        command=["kite", "eval"],
        args=[
            fs.read_text(script_path),
            "--sandbox-path-read=/var/run/secrets/kubernetes.io/serviceaccount",
            "--sandbox-path-write=/work/shared",
            "--sandbox-net-allow",
            "--env=KUBERNETES_SERVICE_HOST",
            "--env=KUBERNETES_SERVICE_PORT",
        ],
        volume_mounts=[
            k8s.obj.volume_mount(name="shared-config", mount_path="/work/shared"),
        ],
    )

    app_container = k8s.obj.container(
        name=app,
        image=kite_image,
        command=["kite", "eval"],
        args=[
            fs.read_text(server_script_path),
            "--sandbox-path-read=/etc/payment-api",
            "--sandbox-net-allow",
        ],
        ports=[k8s.obj.container_port(container_port=8080, name="http")],
        volume_mounts=[
            k8s.obj.volume_mount(name="shared-config", mount_path="/etc/payment-api", read_only=True),
        ],
    )

    dep = k8s.obj.deployment(
        name=app,
        namespace=ns,
        labels={"app": app},
        replicas=2,
        service_account=sa,
        init_containers=[init_container],
        containers=[app_container],
        volumes=[
            k8s.obj.volume(name="shared-config", empty_dir=True),
        ],
    )

    print(k8s.yaml([k8s.obj.namespace(name=ns), sa, role, rb, settings_cm, dep]))
