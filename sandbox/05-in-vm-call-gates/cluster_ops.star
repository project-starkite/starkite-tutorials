#!/usr/bin/env kite
# cluster_ops.star — Demonstrating fine-grained in-VM Starlark call gates (calls.allow / calls.deny)

def check_op(name, result_tuple):
    ok, detail = result_tuple
    status = "ALLOWED" if ok else "DENIED"
    print("  " + name + " : " + status)
    if not ok:
        print("    └─ Reason: " + detail)

def test_read():
    res = fs.try_read_text("config.yaml")
    if res.ok:
        return (True, "Read " + str(len(res.value)) + " bytes")
    return (False, res.error.strip().splitlines()[0])

def test_json():
    # Pure-compute modules (json, yaml, strings, math) are always permitted
    payload = json.encode({"cluster": "prod-k8s-01", "healthy": True})
    return (True, "Encoded " + str(len(payload)) + " bytes")

def test_write():
    res = fs.try_write_text("test_audit.log", "audit-entry\n")
    if res.ok:
        return (True, "Wrote audit log")
    return (False, res.error.strip().splitlines()[0])

def test_delete():
    # Attempting to delete a file — should be blocked by calls.deny: ["fs.delete"]
    res = fs.path("test_audit.log").try_remove()
    if res.ok:
        return (True, "Removed audit log")
    return (False, res.error.strip().splitlines()[0])

def main():
    print("==> [In-VM Call Gate Evaluation] Checking Module & Category Permissions\n")

    check_op("fs.read (config.yaml)", test_read())
    check_op("json.encode (payload)", test_json())
    check_op("fs.write (audit log)", test_write())
    check_op("fs.delete (audit log)", test_delete())

    # Clean up test_audit.log if it exists and deletion wasn't blocked
    if fs.exists("test_audit.log"):
        fs.path("test_audit.log").try_remove()

    print("\n==> [Call Gate Verification Complete]")
