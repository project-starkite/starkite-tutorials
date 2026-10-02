#!/usr/bin/env kite --allow-all
# 02-crud-resources.star - Declarative resource CRUD operations
#
# Demonstrates Tier 1 CRUD lifecycle:
#   - apply: Declarative manifest application
#   - get: Fetch resource by kind and name
#   - label: Add or update resource labels
#   - annotate: Add or update resource annotations
#   - list: Query resources with label selectors
#   - patch: Modify resource spec/data via strategic/merge patch
#   - delete: Remove resource from cluster
#   - try_get: Safe error handling without script abortion
#
# Usage:
#   kite run ./02-crud-resources.star --allow-all

def main():
    client = k8s.config()
    cm_name = "tutorial-app-config"
    ns = client.namespace_name()

    # 1. Apply: Create ConfigMap from a dictionary specification
    print("=== 1. Creating ConfigMap ===")
    cm_manifest = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": cm_name,
            "namespace": ns,
            "labels": {
                "app": "tutorial-app",
            },
        },
        "data": {
            "APP_MODE": "production",
            "LOG_LEVEL": "info",
            "DATABASE_HOST": "postgres.internal",
        },
    }

    applied = client.apply(cm_manifest)
    print("Applied ConfigMap: %s/%s" % (applied.metadata.namespace, applied.metadata.name))

    # 2. Get: Retrieve the resource
    print("\n=== 2. Retrieving ConfigMap ===")
    cm = client.get("configmap", cm_name)
    print("Resource UID: %s" % cm.metadata.uid)
    print("Initial Data:")
    for k, v in cm.data.items():
        print("  %s = %s" % (k, v))

    # 3. Label: Add metadata labels
    print("\n=== 3. Adding Labels ===")
    labeled = client.label("configmap", cm_name, {
        "env": "tutorial",
        "tier": "backend",
    })
    print("Updated Labels:")
    for k, v in labeled.metadata.labels.items():
        print("  %s = %s" % (k, v))

    # 4. Annotate: Add metadata annotations
    print("\n=== 4. Adding Annotations ===")
    annotated = client.annotate("configmap", cm_name, {
        "owner": "platform-team",
        "managed-by": "starkite",
    })
    print("Updated Annotations:")
    for k, v in annotated.metadata.annotations.items():
        print("  %s = %s" % (k, v))

    # 5. List with Label Selector
    print("\n=== 5. Listing Resources by Label Selector ===")
    matching = client.list("configmaps", labels="env=tutorial,tier=backend")
    print("Found %d matching ConfigMap(s):" % len(matching))
    for item in matching:
        print("  - %s (labels: %s)" % (item.metadata.name, dict(item.metadata.labels)))

    # 6. Patch: Update data keys
    print("\n=== 6. Patching ConfigMap Data ===")
    patched = client.patch("configmap", cm_name, {
        "data": {
            "LOG_LEVEL": "debug",
            "FEATURE_METRICS": "enabled",
        },
    })
    print("Patched Data:")
    for k, v in patched.data.items():
        print("  %s = %s" % (k, v))

    # 7. Delete: Remove the resource
    print("\n=== 7. Deleting ConfigMap ===")
    client.delete("configmap", cm_name)
    print("Deleted ConfigMap %s" % cm_name)

    # 8. Verify Deletion using try_get
    print("\n=== 8. Verifying Deletion ===")
    check = client.try_get("configmap", cm_name)
    if not check.ok:
        print("Verified: Resource no longer exists (%s)" % check.error)
    else:
        print("Warning: Resource still exists")
