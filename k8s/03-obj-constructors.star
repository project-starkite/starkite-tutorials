#!/usr/bin/env kite --allow-all
# 03-obj-constructors.star - Typed object constructors and YAML generation
#
# Demonstrates Tier 3 declarative object modeling:
#   - k8s.obj constructors: config_map, deployment, service, container, container_port, env_var, service_port
#   - Workload flattening: pass containers and labels directly to deployment without boilerplate pod templates
#   - k8s.yaml(): Convert Starlark resource objects to single or multi-document Kubernetes YAML
#   - Applying typed objects directly via client.apply()
#   - Waiting for workload readiness with client.wait_for()
#   - Resource cleanup
#
# Usage:
#   kite run ./03-obj-constructors.star --allow-all

def main():
    client = k8s.config()
    ns = client.namespace_name()

    print("=== 1. Defining Resources with k8s.obj Constructors ===")

    # Define a ConfigMap
    cm = k8s.obj.config_map(
        name="web-app-config",
        namespace=ns,
        labels={"app": "web-app", "tier": "frontend"},
        data={
            "APP_ENV": "production",
            "PORT": "80",
        },
    )

    # Define a Deployment with flattened container specification
    dep = k8s.obj.deployment(
        name="web-app-deployment",
        namespace=ns,
        replicas=2,
        labels={"app": "web-app", "tier": "frontend"},
        containers=[
            k8s.obj.container(
                name="web-server",
                image="nginx:1.27-alpine",
                ports=[
                    k8s.obj.container_port(container_port=80, name="http"),
                ],
                env=[
                    k8s.obj.env_var(name="APP_MODE", value="tutorial"),
                ],
            ),
        ],
    )

    # Define a Service exposing the deployment
    svc = k8s.obj.service(
        name="web-app-svc",
        namespace=ns,
        labels={"app": "web-app"},
        selector={"app": "web-app"},
        ports=[
            k8s.obj.service_port(port=8080, target_port=80, name="http"),
        ],
    )

    print("Created typed resource objects in memory.")

    # 2. YAML Export via k8s.yaml()
    print("\n=== 2. Exporting Multi-Document YAML ===")
    yaml_output = k8s.yaml([cm, dep, svc])
    print(yaml_output)

    # 3. Apply the objects to the cluster
    print("=== 3. Applying Objects to Kubernetes ===")
    client.apply(cm)
    client.apply(dep)
    client.apply(svc)
    print("Applied ConfigMap, Deployment, and Service.")

    # 4. Wait for deployment to be available
    print("\n=== 4. Waiting for Deployment Readiness ===")
    print("Waiting for deployment/web-app-deployment condition: Available...")
    client.wait_for("deployment", "web-app-deployment", condition="Available", timeout="60s")
    print("Deployment is ready and available.")

    # 5. Inspect the live deployment
    print("\n=== 5. Inspecting Live Deployment ===")
    live_dep = client.get("deployment", "web-app-deployment")
    print("Replicas desired : %s" % live_dep.spec.replicas)
    print("Replicas ready   : %s" % live_dep.status.readyReplicas)
    print("Replicas updated : %s" % live_dep.status.updatedReplicas)

    # 6. Cleanup
    print("\n=== 6. Cleaning Up Resources ===")
    client.delete("service", "web-app-svc")
    client.delete("deployment", "web-app-deployment")
    client.delete("configmap", "web-app-config")
    print("Cleaned up Service, Deployment, and ConfigMap.")
