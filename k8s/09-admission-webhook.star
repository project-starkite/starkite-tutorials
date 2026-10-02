#!/usr/bin/env kite --allow-all
# 09-admission-webhook.star - Admission Webhook Server (Validating & Mutating)
#
# Demonstrates:
#   - k8s.webhook(): Embedded HTTPS server handling Kubernetes AdmissionReview requests
#   - Validating webhook: Rejecting non-compliant workloads before storage in etcd
#   - Mutating webhook: Modifying manifests on admission and generating RFC 6902 JSONPatches
#   - TLS certificate configuration (strictly required by Kubernetes API server)
#   - Testing via simulated AdmissionReview requests and deploying in-cluster
#
# Usage:
#   # Step 1: Generate temporary self-signed TLS certificates (if needed):
#   openssl req -x509 -newkey rsa:2048 -keyout /tmp/webhook-key.pem \
#       -out /tmp/webhook-cert.pem -days 7 -nodes -subj '/CN=localhost'
#
#   # Step 2: Run the webhook server:
#   kite run ./09-admission-webhook.star --allow-all
#
#   # Step 3 (In another terminal): Test validation rejection:
#   curl -s -k -X POST https://localhost:9443/admit \
#       -H "Content-Type: application/json" \
#       -d '{"apiVersion":"admission.k8s.io/v1","kind":"AdmissionReview","request":{"uid":"req-1","object":{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"bad-deploy"}}}}'
#
#   # Step 4: Test validation passing + mutation patch injection:
#   curl -s -k -X POST https://localhost:9443/admit \
#       -H "Content-Type: application/json" \
#       -d '{"apiVersion":"admission.k8s.io/v1","kind":"AdmissionReview","request":{"uid":"req-2","object":{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"good-deploy","labels":{"team":"platform"}},"spec":{"replicas":3}}}}'

def validate(obj):
    kind = obj.get("kind", "")
    metadata = obj.get("metadata", {})
    labels = metadata.get("labels", {})
    spec = obj.get("spec", {})

    # Rule 1: Require 'team' ownership label on all Deployments
    if kind == "Deployment" and (labels == None or not labels.get("team")):
        return {
            "allowed": False,
            "message": "Admission rejected: 'team' label is required for all deployments",
        }

    # Rule 2: Enforce max replica limit of 5
    replicas = spec.get("replicas", 1) if spec != None else 1
    if replicas != None and replicas > 5:
        return {
            "allowed": False,
            "message": "Admission rejected: replicas (%d) exceeds max allowed limit of 5" % replicas,
        }

    # Admit request
    return {"allowed": True}

def mutate(obj):
    metadata = obj.get("metadata", {})

    # Ensure labels dictionary exists
    if metadata.get("labels") == None:
        obj["metadata"]["labels"] = {}

    # Ensure annotations dictionary exists
    if metadata.get("annotations") == None:
        obj["metadata"]["annotations"] = {}

    # Inject organizational default labels & annotations
    obj["metadata"]["labels"]["managed-by"] = "starkite-admission"
    obj["metadata"]["annotations"]["starkite.io/admitted"] = "true"

    return obj

def main():
    port = var_int("port", 9443)
    cert_path = var_str("tls_cert", "/tmp/webhook-cert.pem")
    key_path = var_str("tls_key", "/tmp/webhook-key.pem")
    path = var_str("path", "/admit")

    print("=== Kubernetes Admission Webhook Server ===")
    print("Endpoint       : https://0.0.0.0:%d%s" % (port, path))
    print("TLS Certificate: %s" % cert_path)
    print("TLS Private Key: %s" % key_path)
    print("Validation     : Enforces 'team' label and max 5 replicas")
    print("Mutation       : Injects 'managed-by: starkite-admission' label")
    print("Listening for AdmissionReview requests (press Ctrl+C to stop)...\n")

    k8s.webhook(
        path = path,
        validate = validate,
        mutate = mutate,
        port = port,
        tls_cert = cert_path,
        tls_key = key_path,
    )
