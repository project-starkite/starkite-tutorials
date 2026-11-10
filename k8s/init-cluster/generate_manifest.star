#!/usr/bin/env kite

def build_stack(
    app="payment-api",
    ns="init-demo",
    app_image="busybox:1.37",
    kite_image="ghcr.io/project-starkite/starkite:v0.11.8",
    script_path="./init_bootstrap.star",
):
    sa = k8s.obj.service_account(
        name=app + "-sa",
        namespace=ns,
        automount_service_account_token=True,
    )
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
    script_cm = k8s.obj.config_map(
        name=app + "-init-script",
        namespace=ns,
        data={"init_bootstrap.star": fs.read_text(script_path)},
    )

    non_root = k8s.obj.security_context(
        run_as_non_root=True,
        run_as_user=65532,
        read_only_root=True,
        capabilities={"drop": ["ALL"]},
    )

    init_container = k8s.obj.container(
        name="config-bootstrap",
        image=kite_image,
        args=[
            "run",
            "/scripts/init_bootstrap.star",
            "--sandbox-path-read=/scripts",
            "--sandbox-path-read=/var/run/secrets/kubernetes.io/serviceaccount",
            "--sandbox-path-write=/work/shared",
            "--sandbox-net-allow",
            "--env=KUBERNETES_SERVICE_HOST",
            "--env=KUBERNETES_SERVICE_PORT",
            "--var=namespace=" + ns,
            "--var=out.dir=/work/shared",
        ],
        security_context=non_root,
        resources=k8s.obj.resource_requirements(
            requests={"cpu": "25m", "memory": "32Mi"},
            limits={"cpu": "100m", "memory": "64Mi"},
        ),
        volume_mounts=[
            k8s.obj.volume_mount(name="shared-config", mount_path="/work/shared"),
            k8s.obj.volume_mount(name="bootstrap-script", mount_path="/scripts", read_only=True),
        ],
    )

    app_container = k8s.obj.container(
        name=app,
        image=app_image,
        command=[
            "sh",
            "-c",
            "cat /etc/payment-api/runtime-config.json && echo '' && cat /etc/payment-api/runtime-config.sha256 && sleep 3600",
        ],
        ports=[k8s.obj.container_port(container_port=8080, name="http")],
        security_context=non_root,
        resources=k8s.obj.resource_requirements(
            requests={"cpu": "100m", "memory": "128Mi"},
            limits={"cpu": "500m", "memory": "256Mi"},
        ),
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
            k8s.obj.volume(name="bootstrap-script", config_map=script_cm),
        ],
    )

    k8s.validate(
        manifest=dep,
        expression="object.spec.template.spec.initContainers.all(c, c.securityContext.runAsNonRoot == true && c.securityContext.readOnlyRootFilesystem == true)",
        strict=True,
    )

    return [k8s.obj.namespace(name=ns), sa, role, rb, settings_cm, script_cm, dep]

def main():
    stack = build_stack(
        app=var_str("app", "payment-api"),
        ns=var_str("namespace", "init-demo"),
        app_image=var_str("image", "busybox:1.37"),
        kite_image=var_str("kite.image", "ghcr.io/project-starkite/starkite:v0.11.8"),
        script_path=var_str("script.path", "./init_bootstrap.star"),
    )
    print(k8s.yaml(stack))
