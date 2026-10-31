#!/usr/bin/env python3
"""reporter.py — Native Python report generator demonstrating Starkite kernel confinement."""

import json
import os
import platform
import socket
import sys
import time

def parse_args():
    args = {"output": None, "input": None, "probe_host": None}
    i = 1
    while i < len(sys.argv):
        arg = sys.argv[i]
        if arg == "--output" and i + 1 < len(sys.argv):
            args["output"] = sys.argv[i + 1]
            i += 2
        elif arg == "--input" and i + 1 < len(sys.argv):
            args["input"] = sys.argv[i + 1]
            i += 2
        elif arg == "--probe-host" and i + 1 < len(sys.argv):
            args["probe_host"] = sys.argv[i + 1]
            i += 2
        else:
            i += 1
    return args

def check_network(host, port=80, timeout=1.5):
    if not host:
        return {"probed": False, "connected": False, "error": "none"}
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((host, port))
        s.close()
        return {"probed": True, "connected": True, "error": None}
    except Exception as e:
        return {"probed": True, "connected": False, "error": str(e)}

def main():
    opts = parse_args()

    # 1. Inspect environment variables (verifies ambient scrubbing vs explicit forwarding)
    env_keys = ["APP_ENV", "STAGE", "SECRET_TOKEN", "AWS_ACCESS_KEY_ID"]
    visible_env = {k: os.environ.get(k) for k in env_keys if k in os.environ}

    # 2. Filesystem read inspection
    input_data = None
    input_read_error = None
    if opts["input"]:
        try:
            with open(opts["input"], "r") as f:
                input_data = f.read().strip()
        except Exception as e:
            input_read_error = str(e)

    # 3. Network egress probe
    net_status = check_network(opts["probe_host"])

    # 4. Generate report payload
    report = {
        "status": "ok",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": {
            "system": platform.system(),
            "python": platform.python_version(),
        },
        "environment": visible_env,
        "input_file": {
            "path": opts["input"],
            "loaded": input_data is not None,
            "bytes": len(input_data) if input_data else 0,
            "error": input_read_error,
        },
        "network": net_status,
    }

    # 5. Filesystem write inspection
    write_error = None
    if opts["output"]:
        try:
            with open(opts["output"], "w") as f:
                json.dump(report, f, indent=2)
            report["output_written"] = True
        except Exception as e:
            report["output_written"] = False
            write_error = str(e)
            report["output_error"] = write_error

    # Output JSON summary to stdout
    print(json.dumps(report, indent=2))

    if input_read_error or write_error:
        sys.exit(1)

if __name__ == "__main__":
    main()
