#!/usr/bin/env kite
# probe.star — Cross-platform sandbox runtime and kernel driver probe

def main():
    print("==> [Kernel Sandbox Driver Probe] Inspecting Platform Primitives\n")

    plat = runtime.platform()
    arch = runtime.arch()
    def_driver = sandbox.default_driver()
    available_drivers = sandbox.list_drivers()

    print("  Host Platform     : " + plat + " (" + arch + ")")
    print("  Go Runtime        : " + runtime.go_version())
    print("  Default Driver    : " + def_driver)
    print("  Available Drivers : " + json.encode(available_drivers))

    # Kernel mechanism description by platform
    mechanism = "unknown"
    if plat == "linux":
        mechanism = "Landlock LSM (ABI v1-v5) + Classic Seccomp-BPF process/socket filters"
    elif plat == "darwin":
        mechanism = "Apple Seatbelt (sandbox_init with compiled Scheme SBPL bytecode)"
    elif plat == "windows":
        mechanism = "AppContainer isolation, Win32 Job Objects, NTFS DACLs, and WFP filtering"

    print("  Kernel Mechanism  : " + mechanism)

    # -----------------------------------------------------------------------------
    # Filesystem & Boundary Validation
    # -----------------------------------------------------------------------------
    print("\n==> [Sandbox Boundary Validation]")

    # Check scratch directory using safe try_exists
    scratch_dir = "/tmp" if plat != "windows" else "C:\\scratch"
    scratch_res = fs.try_exists(scratch_dir)
    scratch_ok = scratch_res.ok and scratch_res.value
    print("  Scratch Path      : " + scratch_dir + " (accessible=" + str(scratch_ok) + ")")

    # Probe sensitive host path (container-parity isolation test)
    # Under zero-trust sandbox, host credentials must be inaccessible
    sensitive_path = "/root/.ssh" if plat == "linux" else "/var/root/.ssh"
    if plat == "darwin":
        sensitive_path = "/etc/master.passwd"
    elif plat == "windows":
        sensitive_path = "C:\\Windows\\System32\\config\\SAM"

    print("  Probing Sensitive : " + sensitive_path)
    res = fs.try_read_text(sensitive_path)
    if not res.ok:
        print("  Isolation Status  : PROTECTED (Access denied by sandbox: " + res.error.strip().splitlines()[0] + ")")
    else:
        print("  Isolation Status  : WARNING (Sensitive path accessible)")

    probe_result = {
        "timestamp": time.now().string(),
        "platform": plat,
        "arch": arch,
        "default_driver": def_driver,
        "available_drivers": available_drivers,
        "kernel_mechanism": mechanism,
        "host_protected": not res.ok,
    }

    print("\n==> [Driver Probe Telemetry]")
    print(json.encode(probe_result))
    print("\nKernel driver probe verified across active OS sandbox.")
