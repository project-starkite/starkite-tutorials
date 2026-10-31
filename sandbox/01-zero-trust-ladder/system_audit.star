#!/usr/bin/env kite
# system_audit.star — Capability ladder audit script across 4 execution phases

# -----------------------------------------------------------------------------
# Phase 1: Pure In-Memory Computation (Allowed under default 'deny-all')
# -----------------------------------------------------------------------------
print("==> [Phase 1] Pure In-Memory Computation")
audit_id = hash.text("system-audit-task-01").sha256()
calc_result = 42 * 1024
telemetry = {
    "audit_id": audit_id,
    "metric": calc_result,
    "timestamp": time.now().string(),
}
print("  SHA256 Digest : " + audit_id[:16] + "...")
print("  Encoded JSON  : " + json.encode(telemetry))
print("  Phase 1 Status: PASSED (Pure computation requires no host privileges)\n")

# -----------------------------------------------------------------------------
# Phase 2: Local Filesystem Inspection (Requires 'sandbox-path' or --sandbox-path-read)
# -----------------------------------------------------------------------------
print("==> [Phase 2] Local Filesystem Inspection")
readme_content = fs.read_text("README.md")
first_line = readme_content.splitlines()[0] if readme_content else "<empty>"
print("  Inspecting    : ./README.md")
print("  Header Text   : " + first_line)
print("  Phase 2 Status: PASSED (Filesystem read authorized)\n")

# -----------------------------------------------------------------------------
# Phase 3: Subprocess Tool Execution (Requires 'sandbox-exec' or --sandbox-exec-allow)
# -----------------------------------------------------------------------------
print("==> [Phase 3] Subprocess Tool Execution")
exec_out = os.exec("echo", ["starkite-audit-worker-active"])
print("  Tool Executed : echo starkite-audit-worker-active")
print("  Process Output: " + exec_out.strip())
print("  Phase 3 Status: PASSED (Subprocess execution authorized)\n")

# -----------------------------------------------------------------------------
# Phase 4: Network Egress (Requires 'sandbox-net' or --sandbox-net-allow)
# -----------------------------------------------------------------------------
print("==> [Phase 4] Outbound Network Egress")
print("  Probing       : https://httpbin.org/get")
response = http.get("https://httpbin.org/get")
print("  HTTP Status   : " + str(response.status_code))
print("  Phase 4 Status: PASSED (Outbound network authorized)\n")

print("==> [Audit Complete] All 4 capability rungs executed successfully!")
