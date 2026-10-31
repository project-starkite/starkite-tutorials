# helper.star - Implementation of acme_helper module

def get_status():
    return {
        "namespace": "acme",
        "name": "acme_helper",
        "version": "1.0.0",
        "loaded_via": "in-memory AST closure pre-loading",
    }

def fetch_upstream():
    resp = http.get("https://httpbin.org/get")
    return {
        "status_code": resp.status_code,
        "endpoint": "https://httpbin.org/get",
    }
