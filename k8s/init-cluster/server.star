#!/usr/bin/env kite

def main():
    cfg = fs.read_text("/etc/payment-api/runtime-config.json")
    sha = fs.read_text("/etc/payment-api/runtime-config.sha256")
    print(cfg)
    print(sha)
    http.serve({"GET /": lambda req: {"status": 200, "headers": {"Content-Type": "application/json"}, "body": cfg}}, port=8080)
