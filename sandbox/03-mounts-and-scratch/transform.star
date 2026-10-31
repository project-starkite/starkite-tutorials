#!/usr/bin/env kite
# transform.star — Dataset processing demonstrating read-only mounts, tmpfs scratch, and W^X invariants

def main():
    # -----------------------------------------------------------------------------
    # 1. Resolve Read-Only Dataset Mount
    # -----------------------------------------------------------------------------
    print("==> [Step 1] Resolving Read-Only Dataset")
    csv_path = None
    if fs.exists("./data/records.csv"):
        csv_path = "./data/records.csv"
    elif fs.exists("data/records.csv"):
        csv_path = "data/records.csv"

    if not csv_path:
        print("Error: records.csv not found in ./data.")
        print("Hint: mount the dataset using --sandbox-mount ./data:ro")
        os.exit(1)

    resolved_path = fs.path(csv_path).resolve().string
    print("  Input Dataset : " + resolved_path)

    # -----------------------------------------------------------------------------
    # 2. Parse and Aggregate Records
    # -----------------------------------------------------------------------------
    print("==> [Step 2] Processing Records via CSV Module")
    records = csv.file(resolved_path).read(header=True)
    print("  Total Records : " + str(len(records)))

    running_count = 0
    total_cores = 0
    total_memory = 0
    active_regions = {}

    for r in records:
        status = r.get("status", "").strip()
        if status == "running":
            running_count += 1
            cores = int(r.get("cpu_cores", "0"))
            mem = int(r.get("memory_gb", "0"))
            region = r.get("region", "unknown")
            total_cores += cores
            total_memory += mem
            active_regions[region] = active_regions.get(region, 0) + 1

    summary = {
        "generated_at": time.now().string(),
        "total_nodes": len(records),
        "running_nodes": running_count,
        "allocated_cores": total_cores,
        "allocated_memory_gb": total_memory,
        "active_regions": active_regions,
    }

    print("  Running Nodes : " + str(running_count))
    print("  Total Cores   : " + str(total_cores))
    print("  Total RAM (GB): " + str(total_memory) + "\n")

    # -----------------------------------------------------------------------------
    # 3. Ephemeral Scratch Storage Operations
    # -----------------------------------------------------------------------------
    print("==> [Step 3] Staging Intermediates to Ephemeral Scratch Storage")
    scratch_dir = "/tmp/scratch" if runtime.platform() != "windows" else "C:\\scratch"
    scratch_file = scratch_dir + "/summary.json"
    print("  Target Scratch: " + scratch_file)

    # Write summary artifact to scratch
    write_res = fs.try_write_text(scratch_file, json.encode(summary))
    if not write_res.ok:
        print("  Scratch Write : FAILED (" + write_res.error + ")")
        print("  Hint: pass --sandbox-mount tmpfs:" + scratch_dir + " on CLI")
        os.exit(1)

    print("  Scratch Write : OK (Wrote " + str(len(json.encode(summary))) + " bytes)")

    # Read back artifact to confirm roundtrip
    read_back = fs.read_text(scratch_file)
    print("  Verification  : Scratch readback confirmed (" + str(len(read_back)) + " bytes)\n")

    # -----------------------------------------------------------------------------
    # 4. Write-XOR-Execute (W^X) Invariant Verification
    # -----------------------------------------------------------------------------
    print("==> [Step 4] Enforcing Write-XOR-Execute (W^X) Invariant")
    exploit_script = scratch_dir + "/exploit.sh"
    fs.write_text(exploit_script, "#!/bin/sh\necho 'injected exploit payload'\n")
    fs.path(exploit_script).chmod(0o755)

    # In Starkite, all writable scratch mounts are mounted noexec.
    # The OS kernel blocks executing binaries or scripts directly from writable locations.
    print("  Staged Script : " + exploit_script + " (chmod 0755 in rw,noexec mount)")
    exec_res = os.try_exec(exploit_script, [])
    if not exec_res.ok:
        print("  Kernel W^X    : ENFORCED (Direct execution blocked: " + exec_res.error.strip() + ")")
    else:
        print("  Kernel W^X    : Warning: direct execution permitted under active profile")

    print("\n==> [Complete] Transform pipeline successfully executed under strict mount confinement!")
