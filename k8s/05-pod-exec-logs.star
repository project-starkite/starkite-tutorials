#!/usr/bin/env kite --allow-all
# 05-pod-exec-logs.star - Pod I/O, command execution, and live logs
#
# Demonstrates Tier 1 Pod I/O:
#   - Creating an active diagnostic pod using k8s.obj.pod
#   - Waiting for pod readiness with client.wait_for()
#   - Executing shell commands using string syntax (/bin/sh -c)
#   - Executing structured commands using list syntax (direct exec)
#   - Inspecting execution results: stdout, stderr, and exit code
#   - Fetching container logs with client.logs() and tail limit
#   - Cleaning up the diagnostic pod
#
# Usage:
#   kite run ./05-pod-exec-logs.star --allow-all

def main():
    client = k8s.config()
    pod_name = "diagnostic-runner"
    ns = client.namespace_name()

    # 1. Create a lightweight diagnostic pod
    print("=== 1. Creating Diagnostic Pod ===")
    pod_manifest = k8s.obj.pod(
        name=pod_name,
        namespace=ns,
        labels={"app": "diagnostic-tool"},
        containers=[
            k8s.obj.container(
                name="toolbox",
                image="busybox:1.36",
                command=[
                    "sh", "-c",
                    "echo 'Diagnostic container initialized'; while true; do date; sleep 5; done"
                ],
            ),
        ],
    )
    client.apply(pod_manifest)
    print("Applied pod manifest: %s/%s" % (ns, pod_name))

    # 2. Wait for pod Ready condition
    print("\n=== 2. Waiting for Pod Readiness ===")
    print("Waiting for pod/%s condition: Ready..." % pod_name)
    client.wait_for("pod", pod_name, condition="Ready", timeout="60s")
    print("Pod is running and Ready.")

    # 3. Execute command using shell string syntax
    print("\n=== 3. Executing Shell Command (String Syntax) ===")
    cmd_str = "uname -srm && id"
    print("Running: %s" % cmd_str)
    res_str = client.exec(pod_name, cmd_str)
    print("Exit Code: %d" % res_str.code)
    print("Output:\n%s" % res_str.stdout.strip())

    # 4. Execute command using structured argument list
    print("\n=== 4. Executing Command (List Syntax) ===")
    cmd_list = ["cat", "/etc/hosts"]
    print("Running: %s" % cmd_list)
    res_list = client.exec(pod_name, cmd_list)
    print("Exit Code: %d" % res_list.code)
    print("Output:\n%s" % res_list.stdout.strip())

    # 5. File creation and verification via exec
    print("\n=== 5. In-Container File Operations ===")
    client.exec(pod_name, "echo 'Generated inside container' > /tmp/report.txt")
    verify_res = client.exec(pod_name, ["cat", "/tmp/report.txt"])
    print("Read back file content: %s" % verify_res.stdout.strip())

    # 6. Non-zero exit code handling
    print("\n=== 6. Error Handling on Non-Zero Exit Code ===")
    err_res = client.exec(pod_name, "ls /nonexistent-path-99")
    print("Exit Code : %d" % err_res.code)
    print("Stderr    : %s" % err_res.stderr.strip())

    # 7. Fetch container logs
    print("\n=== 7. Fetching Pod Logs ===")
    log_content = client.logs(pod_name, tail=5)
    print("Last 5 log lines:")
    for line in log_content.strip().split("\n"):
        print("  | %s" % line)

    # 8. Cleanup
    print("\n=== 8. Cleaning Up Pod ===")
    client.delete("pod", pod_name)
    print("Deleted pod %s." % pod_name)
