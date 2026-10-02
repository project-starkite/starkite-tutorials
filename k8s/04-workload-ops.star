#!/usr/bin/env kite --allow-all
# 04-workload-ops.star - High-level workload management operations
#
# Demonstrates Tier 2 kubectl abstractions:
#   - deploy: One-shot creation of Deployment + Service without YAML
#   - wait_for: Polling for resource conditions (e.g. Available, Ready)
#   - scale: Dynamically updating workload replica counts
#   - rollout: Inspecting rollout status and triggering rolling restarts
#   - set_image: Updating container images in-place
#   - describe: Inspecting workload details, status conditions, and events
#   - delete: Removing workloads and services
#
# Usage:
#   kite run ./04-workload-ops.star --allow-all

def main():
    client = k8s.config()
    app_name = "demo-web"

    # 1. Deploy workload and companion service in one call
    print("=== 1. Deploying Workload ===")
    result = client.deploy(
        app_name,
        "nginx:1.27-alpine",
        replicas=2,
        port=80,
        labels={"app": app_name, "team": "platform"},
        env={"APP_ENV": "tutorial"},
    )
    print("Deployed workload:")
    print("  Deployment: %s" % result.deployment)
    if result.get("service"):
        print("  Service   : %s" % result.service)

    # 2. Wait for deployment to become available
    print("\n=== 2. Waiting for Initial Rollout ===")
    print("Waiting for deployment/%s condition: Available..." % app_name)
    client.wait_for("deployment", app_name, condition="Available", timeout="60s")
    print("Rollout completed successfully.")

    # 3. Inspect rollout status
    print("\n=== 3. Checking Rollout Status ===")
    status = client.rollout("deployment", app_name, action="status")
    print("Rollout status:")
    print("  Replicas desired  : %d" % status.replicas)
    print("  Replicas ready    : %d" % status.ready)
    print("  Replicas updated  : %d" % status.updated)
    print("  Replicas available: %d" % status.available)
    print("  Rollout complete  : %s" % status.complete)

    # 4. Scale up the workload
    print("\n=== 4. Scaling Deployment ===")
    print("Scaling deployment/%s to 3 replicas..." % app_name)
    client.scale("deployment", app_name, 3)
    client.wait_for("deployment", app_name, condition="Available", timeout="60s")

    updated_dep = client.get("deployment", app_name)
    print("Confirmed replicas spec: %d" % updated_dep.spec.replicas)

    # 5. Update container image
    print("\n=== 5. Updating Container Image ===")
    print("Updating container image to nginx:alpine-slim...")
    client.set_image("deployment", app_name, app_name, "nginx:alpine-slim")
    client.wait_for("deployment", app_name, condition="Available", timeout="60s")
    print("Image update rollout completed.")

    # 6. Describe workload conditions and recent events
    print("\n=== 6. Describing Workload Status ===")
    info = client.describe("deployment", app_name)

    print("Conditions:")
    for cond in info.conditions:
        print("  - %s: %s (Reason: %s, Message: %s)" % (
            cond.type, cond.status, cond.get("reason", "None"), cond.get("message", "")
        ))

    if info.events:
        print("\nRecent Events (%d found):" % len(info.events))
        for ev in info.events[-5:]:
            print("  - [%s] %s: %s" % (ev.type, ev.reason, ev.message))

    # 7. Rollout restart
    print("\n=== 7. Triggering Rolling Restart ===")
    client.rollout("deployment", app_name, action="restart")
    client.wait_for("deployment", app_name, condition="Available", timeout="60s")
    print("Rolling restart completed.")

    # 8. Cleanup
    print("\n=== 8. Cleaning Up Workload ===")
    client.delete("deployment", app_name)
    if result.get("service"):
        client.delete("service", app_name)
    print("Cleaned up deployment and service for %s." % app_name)
