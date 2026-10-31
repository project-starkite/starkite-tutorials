#!/usr/bin/env kite
# container_task.star — Automated workload executing inside an ephemeral OCI container sandbox

def main():
    print("==> [Container Sandbox Execution] Initializing Workload\n")

    # 1. Environment & Container Telemetry
    print("1. Container Environment Metadata:")
    print("   Platform        : " + runtime.platform() + " (" + runtime.arch() + ")")
    print("   Go Version      : " + runtime.go_version())
    print("   CPUs Available  : " + str(runtime.cpu_count()))

    # Check for container filesystem signatures
    is_docker = fs.try_exists("/.dockerenv").ok and fs.try_exists("/.dockerenv").value
    cgroup_info = "<not accessible>"
    cgroup_res = fs.try_read_text("/proc/1/cgroup")
    if cgroup_res.ok:
        first_cgroup = cgroup_res.value.strip().splitlines()[0] if cgroup_res.value else ""
        cgroup_info = first_cgroup[:40]

    print("   /.dockerenv     : " + str(is_docker))
    print("   cgroup Signature: " + cgroup_info)

    # 2. Ephemeral In-Memory Computation
    print("\n2. Processing Bounded Container Workload:")
    records_count = 5000
    calc_hash = hash.text("container-task-" + str(records_count)).sha256()
    print("   Batch Size      : " + str(records_count) + " records")
    print("   Result SHA-256  : " + calc_hash[:24] + "...")

    # 3. Network Isolation Verification
    print("\n3. Testing Container Network Isolation:")
    net_probe = http.try_get("https://httpbin.org/get", timeout="2s")
    if not net_probe.ok:
        print("   Network Status  : AIR-GAPPED (Outbound socket blocked: " + net_probe.error.strip().splitlines()[0] + ")")
    else:
        print("   Network Status  : CONNECTED (HTTP " + str(net_probe.value.status_code) + ")")

    telemetry = {
        "timestamp": time.now().string(),
        "runtime": runtime.platform(),
        "dockerenv_present": is_docker,
        "batch_hash": calc_hash,
        "network_airgapped": not net_probe.ok,
    }

    print("\n==> [Container Task Completed Successfully]")
    print(json.encode(telemetry))
