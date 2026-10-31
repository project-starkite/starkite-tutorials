#!/usr/bin/env kite
# health_check.star — Remote service health prober demonstrating network confinement and DNS/TLS auto-unveiling

def probe_endpoint(url, label):
    print("  Probing       : " + label + " (" + url + ")")
    res = http.try_get(url, timeout="5s")
    if not res.ok:
        print("  Status        : BLOCKED / FAILED")
        print("  Diagnostic    : " + res.error.strip())
        return {"url": url, "label": label, "ok": False, "error": res.error.strip()}

    resp = res.value
    body_snippet = resp.get_text().strip()
    if len(body_snippet) > 60:
        body_snippet = body_snippet[:57] + "..."

    print("  Status        : OK (HTTP " + str(resp.status_code) + ")")
    print("  Response Body : " + body_snippet)
    return {"url": url, "label": label, "ok": True, "status_code": resp.status_code}

def main():
    print("==> [Network Confinement Audit] Probing Infrastructure Endpoints\n")

    endpoints = [
        ("https://api.github.com/zen", "GitHub Zen API"),
        ("https://httpbin.org/get", "HTTPBin Echo Service"),
    ]

    results = []
    for url, label in endpoints:
        info = probe_endpoint(url, label)
        results.append(info)
        print("")

    success_count = 0
    for r in results:
        if r["ok"]:
            success_count += 1

    summary = {
        "timestamp": time.now().string(),
        "total_probed": len(endpoints),
        "successful": success_count,
        "all_passed": success_count == len(endpoints),
    }

    print("==> [Health Check Summary]")
    print(json.encode(summary))

    if success_count == 0:
        print("\nNotice: Script is running under air-gapped network confinement.")
        print("Hint: Rerun with outbound networking authorized:")
        print("  kite run ./health_check.star --sandbox-net-allow")
        print("  kite run ./health_check.star --sandbox-profile=sandbox-net")
    elif success_count == len(endpoints):
        print("\nAll endpoints reached successfully under authorized network policy.")
