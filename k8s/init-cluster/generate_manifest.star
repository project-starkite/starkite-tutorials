#!/usr/bin/env kite

def main():
    app = var_str("app", "payment-api")
    ns = var_str("namespace", "init-demo")
    app_image = var_str("image", "busybox:1.37")
    kite_image = var_str("kite.image", "ghcr.io/project-starkite/starkite:v0.11.8")
    script_path = var_str("script.path", "./init_bootstrap.star")

    script_res = fs.path(script_path).try_read_text()
    if not script_res.ok:
        fail("failed to read init script %s: %s" % (script_path, script_res.error))

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

    script_cm = k8s.obj.config_map(
        name=app + "-init-script",
        namespace=ns,
        data={
            "init_bootstrap.star": script_res.value,
        },
    )

    non_root_ctx = k8s.obj.security_context(
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
            "--env",
            "KUBERNETES_SERVICE_HOST",
            "--env",
            "KUBERNETES_SERVICE_PORT",
            "--var",
            "namespace=" + ns,
            "--var",
            "out.dir=/work/shared",
        ],
        security_context=non_root_ctx,
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
        security_context=non_root_ctx,
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
        service_account=sa_name,
        init_containers=[init_container],
        containers=[app_container],
        volumes=[
            k8s.obj.volume(name="shared-config", empty_dir={}),
            k8s.obj.volume(name="bootstrap-script", config_map={"name": app + "-init-script"}),
        ],
    )

    check = k8s.try_validate(
        manifest=dep,
        expression="object.spec.template.spec.initContainers.all(c, c.securityContext.runAsNonRoot == true && c.securityContext.readOnlyRootFilesystem == true)",
    )
    if not check.ok:
        fail("validation call failed: %s" % check.error)
    if not check.value.valid:
        fail("init container security validation failed: %s" % check.value.violations)

    stack = [ns_obj, sa_obj, role_obj, rb_obj, settings_cm, script_cm, dep]
    print(k8s.yaml(stack))
