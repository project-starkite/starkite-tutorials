#!/usr/bin/env kite
# service-watchdog.star — Self-healing Windows service monitor and recovery runbook
#
# This script monitors a target Windows service, automatically restarts it
# with exponential backoff if stopped, and verifies its HTTP health endpoint.

# -----------------------------------------------------------------------------
# 1. CLI Options & Configuration Schema
# -----------------------------------------------------------------------------
args.string(
    "service",
    shorthand = "s",
    default = "Spooler",
    help = "Target Windows service name (e.g. Spooler, W3SVC, docker)",
)

args.string(
    "health-url",
    shorthand = "u",
    default = "http://localhost:8080/healthz",
    help = "Application HTTP health check endpoint to probe",
)

args.string(
    "webhook-url",
    shorthand = "w",
    default = "",
    help = "Webhook URL for incident notification if recovery fails",
)

args.bool(
    "dry-run",
    default = False,
    help = "Preview service checks without restarting or altering state",
)

# -----------------------------------------------------------------------------
# 2. Helper: Safe JSON Decoding
# -----------------------------------------------------------------------------
def safe_json_decode(text):
    s = text.strip()
    if not s or not (s.startswith("{") or s.startswith("[")):
        return None
    res = json.try_decode(s)
    if res.ok:
        return res.value
    return None

# -----------------------------------------------------------------------------
# 3. Main Watchdog Execution
# -----------------------------------------------------------------------------
def main():
    opts = args.parse()

    if runtime.platform() != "windows":
        print("Notice: Current platform is '%s'. Running against platform defaults." % runtime.platform())

    ps = os.powershell(timeout = "30s")

    # Step A: Query Windows Service status as structured JSON
    cmd = "Get-Service -Name '" + opts.service + "' -ErrorAction SilentlyContinue | Select-Object Status, StartType | ConvertTo-Json -Compress"
    res = ps.try_exec(cmd)
    svc = safe_json_decode(res.stdout) if res.ok else None

    if not svc:
        print("Error: Windows service '%s' not found on this host." % opts.service)
        return

    status = svc.get("Status")
    print("Inspecting Windows service '%s': status is %s" % (opts.service, status))

    # Step B: Auto-remediate with exponential backoff if stopped
    # ServiceControllerStatus enum: 4 = Running, 1 = Stopped
    is_running = status == 4 or status == "Running" or status == 4.0
    if not is_running:
        print("Service '%s' is stopped. Initiating self-healing restart..." % opts.service)

        if opts.dry_run:
            print("[Dry-Run] Would attempt service restart with exponential backoff.")
            return

        def restart():
            r = ps.try_exec("Restart-Service -Name '" + opts.service + "' -Force")
            if not r.ok:
                fail("Service restart failed: " + r.stderr.strip())

        recovery = retry.with_backoff(
            restart,
            max_attempts = 3,
            delay = "2s",
            max_delay = "10s",
            jitter = True,
        )

        if not recovery.ok:
            print("Recovery failed after %d attempts: %s" % (recovery.attempts, recovery.error))
            if opts.webhook_url:
                payload = {
                    "event": "service_recovery_failed",
                    "service": opts.service,
                    "host": os.hostname(),
                    "attempts": recovery.attempts,
                    "error": recovery.error,
                }
                http.try_post(opts.webhook_url, body = payload, timeout = "5s")
                print("Incident alert dispatched to webhook.")
            return

        print("Service '%s' successfully restarted." % opts.service)

    # Step C: Verify application HTTP health endpoint
    probe = http.try_get(opts.health_url, timeout = "5s")
    if probe.ok and probe.value.status_code == 200:
        print("Application probe OK: '%s' returned HTTP 200." % opts.health_url)
    else:
        status_info = ("HTTP " + str(probe.value.status_code)) if probe.ok else probe.error
        print("Warning: Application probe for '%s' reported: %s" % (opts.health_url, status_info))
