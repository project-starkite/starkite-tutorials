#!/usr/bin/env kite --allow-all
# 06-node-ops.star - Node maintenance operations (cordon and uncordon)
#
# Demonstrates Tier 2 node operations:
#   - Node discovery and schedulability status inspection
#   - cordon: Marking a node unschedulable to prevent new workload placement
#   - uncordon: Restoring a node to schedulable status
#   - Inspecting node capacity and allocatable compute resources
#
# Usage:
#   kite run ./06-node-ops.star --allow-all
#   kite run ./06-node-ops.star --var node=kind-control-plane --allow-all

def main():
    client = k8s.config()

    # 1. Discover nodes
    print("=== 1. Discovering Cluster Nodes ===")
    nodes = client.list("nodes")
    if not nodes:
        print("Error: No nodes found in cluster.")
        return

    # Select target node from --var node=<name> or default to the first node
    target_name = var_str("node", nodes[0].metadata.name)
    print("Target Node: %s (of %d available nodes)" % (target_name, len(nodes)))

    # 2. Inspect initial node state
    print("\n=== 2. Initial Node State ===")
    node = client.get("node", target_name)
    initial_unschedulable = node.spec.get("unschedulable", False)
    print("Node Name      : %s" % node.metadata.name)
    print("Unschedulable  : %s" % initial_unschedulable)
    print("Allocatable CPU: %s" % node.status.allocatable.get("cpu", "unknown"))
    print("Allocatable Mem: %s" % node.status.allocatable.get("memory", "unknown"))

    # 3. Cordon the node
    print("\n=== 3. Cordoning Node ===")
    print("Marking node %s as unschedulable..." % target_name)
    cordoned = client.cordon(target_name)
    is_cordoned = cordoned.spec.get("unschedulable", False)
    print("Cordon result: spec.unschedulable = %s" % is_cordoned)

    # 4. Verify cordoned state via fresh get()
    print("\n=== 4. Verifying Cordoned State ===")
    verified_cordon = client.get("node", target_name)
    print("Live node state: spec.unschedulable = %s" % (
        verified_cordon.spec.get("unschedulable", False)
    ))

    # 5. Uncordon the node
    print("\n=== 5. Uncordoning Node ===")
    print("Restoring node %s to schedulable..." % target_name)
    uncordoned = client.uncordon(target_name)
    is_still_unschedulable = uncordoned.spec.get("unschedulable", False)
    print("Uncordon result: spec.unschedulable = %s" % is_still_unschedulable)

    # 6. Verify restored state
    print("\n=== 6. Verifying Restored State ===")
    verified_uncordon = client.get("node", target_name)
    print("Live node state: spec.unschedulable = %s" % (
        verified_uncordon.spec.get("unschedulable", False)
    ))
    print("Node maintenance check completed.")
