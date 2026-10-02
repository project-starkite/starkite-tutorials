#!/usr/bin/env kite --allow-all
# 01-hello-k8s.star - Cluster connection, version check, and node discovery
#
# Demonstrates:
#   - Connecting via k8s.config() and top-level k8s module
#   - Inspecting cluster version, context, and namespace
#   - Listing and inspecting cluster nodes and namespaces
#
# Usage:
#   kite run ./01-hello-k8s.star --allow-all

def main():
    # Initialize a client using active kubeconfig context
    client = k8s.config()

    print("=== Kubernetes Cluster Info ===")
    ver = client.version()
    print("Kubernetes Version : %s (Major: %s, Minor: %s, Platform: %s)" % (
        ver.git_version, ver.major, ver.minor, ver.platform
    ))
    print("Current Context    : %s" % client.context())
    print("Default Namespace  : %s" % client.namespace_name())

    # Control plane endpoint (when configured or inferred)
    server = client.server()
    if server:
        print("API Server Endpoint: %s" % server)

    # Discover and inspect nodes
    print("\n=== Cluster Nodes ===")
    nodes = client.list("nodes")
    print("Total Nodes: %d" % len(nodes))

    for node in nodes:
        name = node.metadata.name
        status = node.status
        node_info = status.get("nodeInfo", {})
        kubelet_ver = node_info.get("kubeletVersion", "unknown")
        os_image = node_info.get("osImage", "unknown")
        arch = node_info.get("architecture", "unknown")

        # Determine Ready condition
        ready = "Unknown"
        for cond in status.get("conditions", []):
            if cond.get("type") == "Ready":
                ready = cond.get("status", "Unknown")
                break

        # Check unschedulable flag
        unschedulable = node.spec.get("unschedulable", False)
        sched_status = "SchedulingDisabled" if unschedulable else "Schedulable"

        print("  - Node: %s" % name)
        print("    Ready: %s | State: %s" % (ready, sched_status))
        print("    Kubelet: %s | OS: %s (%s)" % (kubelet_ver, os_image, arch))

    # Discover namespaces
    print("\n=== Namespaces ===")
    namespaces = client.list("namespaces")
    ns_names = [ns.metadata.name for ns in namespaces]
    print("Found %d namespace(s): %s" % (len(ns_names), ", ".join(ns_names)))
