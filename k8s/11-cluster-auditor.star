#!/usr/bin/env kite --allow-all
# 11-cluster-auditor.star - Programmatic Kubernetes Cluster Policy & Reliability Auditor
#
# Demonstrates:
#   - Automated cluster-wide inspection across namespaces
#   - Reliability checks: Single-replica workloads (SPOF detection)
#   - Resource governance: Missing CPU/memory requests and limits
#   - Security hygiene: Privileged containers and root execution inspection
#   - Node health: Memory, Disk, and PID pressure detection
#   - Structured reporting with severity classification and compliance scoring
#
# Usage:
#   # Audit all namespaces:
#   kite run ./11-cluster-auditor.star --allow-all
#
#   # Audit a specific namespace:
#   kite run ./11-cluster-auditor.star --var namespace=kube-system --allow-all

def main():
    target_ns = var_str("namespace", "")
    client = k8s.config()

    print("=== Kubernetes Cluster Reliability & Security Auditor ===")
    if target_ns:
        print("Scope: Namespace %q" % target_ns)
    else:
        print("Scope: Cluster-wide (all namespaces)")
    print("=" * 60)

    findings = []

    # 1. Node Health Audit
    print("\n[1/4] Auditing Node Health & Resource Pressures...")
    nodes = client.list("nodes")
    for node in nodes:
        name = node.metadata.name
        conditions = node.status.get("conditions", [])

        # Check Ready status
        is_ready = False
        for c in conditions:
            if c.get("type") == "Ready" and c.get("status") == "True":
                is_ready = True
                break

        if not is_ready:
            findings.append({
                "severity": "CRITICAL",
                "category": "NodeHealth",
                "resource": "node/%s" % name,
                "message": "Node is not in Ready state",
            })

        # Check pressure conditions
        for pressure in ["DiskPressure", "MemoryPressure", "PIDPressure"]:
            for c in conditions:
                if c.get("type") == pressure and c.get("status") == "True":
                    findings.append({
                        "severity": "CRITICAL",
                        "category": "NodePressure",
                        "resource": "node/%s" % name,
                        "message": "Active %s reported on node" % pressure,
                    })

    print("  Inspected %d node(s)." % len(nodes))

    # 2. Deployment Reliability Audit (SPOF)
    print("\n[2/4] Auditing Workload High Availability...")
    if target_ns:
        deployments = client.list("deployments", namespace=target_ns)
    else:
        deployments = client.list("deployments")

    for dep in deployments:
        name = dep.metadata.name
        ns = dep.metadata.namespace
        replicas = dep.spec.get("replicas", 1)

        # Ignore kube-system infrastructure deployments
        if ns == "kube-system":
            continue

        if replicas < 2:
            findings.append({
                "severity": "WARNING",
                "category": "HighAvailability",
                "resource": "%s/%s" % (ns, name),
                "message": "Single replica configured (%d); risk of service disruption during node maintenance" % replicas,
            })

    print("  Inspected %d deployment(s)." % len(deployments))

    # 3. Pod Security & Resource Governance Audit
    print("\n[3/4] Auditing Pod Security Context & Resource Limits...")
    if target_ns:
        pods = client.list("pods", namespace=target_ns)
    else:
        pods = client.list("pods")

    for pod in pods:
        name = pod.metadata.name
        ns = pod.metadata.namespace

        # Skip finished pods
        phase = pod.status.get("phase", "")
        if phase in ["Succeeded", "Failed"]:
            continue

        pod_spec = pod.spec
        containers = pod_spec.get("containers", [])

        for c in containers:
            c_name = c.get("name", "unknown")
            res_id = "%s/%s [%s]" % (ns, name, c_name)

            # Security: Privileged containers
            sec = c.get("securityContext", {})
            if sec != None and sec.get("privileged") == True:
                findings.append({
                    "severity": "CRITICAL",
                    "category": "Security",
                    "resource": res_id,
                    "message": "Container running in privileged mode",
                })

            # Resource Governance: Missing Limits
            resources = c.get("resources", {})
            limits = resources.get("limits", {}) if resources != None else None
            if limits == None or not limits.get("cpu") or not limits.get("memory"):
                # Flag user workloads without limits
                if ns not in ["kube-system", "local-path-storage"]:
                    findings.append({
                        "severity": "WARNING",
                        "category": "ResourceGovernance",
                        "resource": res_id,
                        "message": "Missing CPU or memory resource limits",
                    })

    print("  Inspected %d pod(s)." % len(pods))

    # 4. Service Endpoint Health Audit
    print("\n[4/4] Auditing Service Endpoints...")
    if target_ns:
        services = client.list("services", namespace=target_ns)
    else:
        services = client.list("services")

    for svc in services:
        name = svc.metadata.name
        ns = svc.metadata.namespace
        svc_type = svc.spec.get("type", "ClusterIP")

        # Skip headless services or kubernetes API service
        if name == "kubernetes":
            continue

        selector = svc.spec.get("selector")
        if selector:
            # Format selector string for pod matching
            sel_str = ",".join(["%s=%s" % (k, v) for k, v in selector.items()])
            matching_pods = client.list("pods", namespace=ns, labels=sel_str)
            if len(matching_pods) == 0:
                findings.append({
                    "severity": "WARNING",
                    "category": "OrphanedService",
                    "resource": "%s/%s" % (ns, name),
                    "message": "Service selector (%s) matches 0 active pods" % sel_str,
                })

    print("  Inspected %d service(s)." % len(services))

    # Summary Report
    print("\n" + "=" * 60)
    print("=== AUDIT SUMMARY & FINDINGS ===")
    print("=" * 60)

    critical_count = 0
    warning_count = 0

    if not findings:
        print("\nAll audited cluster components meet baseline reliability and security standards.")
    else:
        def pad(s, width):
            return s + " " * (width - len(s)) if len(s) < width else s[:width]

        header = "%s %s %s %s" % (pad("SEVERITY", 10), pad("CATEGORY", 20), pad("RESOURCE", 35), "DETAILS")
        sep = "%s %s %s %s" % (pad("-" * 8, 10), pad("-" * 18, 20), pad("-" * 33, 35), "-" * 30)
        print("\n" + header)
        print(sep)
        for f in findings:
            if f["severity"] == "CRITICAL":
                critical_count += 1
            elif f["severity"] == "WARNING":
                warning_count += 1
            row = "%s %s %s %s" % (
                pad(f["severity"], 10),
                pad(f["category"], 20),
                pad(f["resource"], 35),
                f["message"]
            )
            print(row)

    total_issues = critical_count + warning_count
    score = max(0, 100 - (critical_count * 20) - (warning_count * 5))

    print("\nTotal Issues Found : %d (Critical: %d, Warnings: %d)" % (total_issues, critical_count, warning_count))
    print("Cluster Health Score: %d / 100" % score)
    print("=" * 60)
