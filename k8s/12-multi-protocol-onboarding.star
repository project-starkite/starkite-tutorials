#!/usr/bin/env kite --allow-all
# 12-multi-protocol-onboarding.star - Multi-Protocol Platform Onboarding & Last-Mile Orchestration
#
# Demonstrates:
#   - Multi-Protocol Orchestration: Combining relational database migrations (sql) with Kubernetes workloads (k8s)
#   - The "Last-Mile" Platform Solution: Bridging the gap where Crossplane/Terraform provision cloud resources
#     (e.g., RDS instances) but cannot run SQL schema migrations or seed initial tenant records
#   - Deterministic Lifecycle: defer() ensures database connections and file handles are closed on exit or signal
#   - Resilient Atomic Transactions: db.tx() rolls back database changes on error, avoiding dirty partial state
#   - Typed Object Modeling: k8s.obj.* constructors for Namespace, ConfigMap, and Deployment
#   - Dual-Mode Delivery: Generates multi-document YAML via k8s.yaml() for GitOps / piping, or applies directly
#     via Server-Side Apply (k8s.apply)
#
# Usage:
#   # 1. Default (Manifest mode): prints operational audit to stderr, clean YAML to stdout:
#   kite run ./12-multi-protocol-onboarding.star
#
#   # 2. Customize tenant and service tier:
#   kite run ./12-multi-protocol-onboarding.star --var tenant=globex --var tier=enterprise
#
#   # 3. Pipe directly into kubectl:
#   kite run ./12-multi-protocol-onboarding.star --var tenant=initech | kubectl apply -f -
#
#   # 4. Direct cluster apply (synchronizes directly via Server-Side Apply):
#   kite run ./12-multi-protocol-onboarding.star --var mode=apply

def run_last_mile_db_migration(db_driver, db_dsn, tenant, tier):
    """Executes schema creation and seeds tenant record in an atomic transaction."""
    printf("[Step 1/3] Connecting to database (%s: %s)...\n", db_driver, db_dsn)
    db = sql.open(db_driver, db_dsn)
    
    # 1. Deterministic Cleanup: Closes connection pool on exit or signal
    defer(lambda: (db.close(), printf("[Cleanup] Closed %s database connection.\n", db_driver)))

    def migrate(tx):
        # Create metadata schema / table
        tx.exec("""
            CREATE TABLE IF NOT EXISTS tenant_registry (
                tenant_id TEXT PRIMARY KEY,
                tier TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        # Seed initial tenant state
        tx.exec("""
            INSERT INTO tenant_registry (tenant_id, tier, status)
            VALUES (?, ?, ?)
            ON CONFLICT (tenant_id) DO UPDATE SET tier = ?, status = ?
        """, tenant, tier, "ACTIVE", tier, "ACTIVE")

    # 2. Atomic Transaction: Rolls back automatically if any query fails
    db.tx(migrate)
    
    # Verify migration results
    rows = db.query("SELECT tenant_id, tier, status FROM tenant_registry WHERE tenant_id = ?", tenant)
    if len(rows) > 0:
        row = rows[0]
        printf("[Step 1/3 SUCCESS] Tenant DB record initialized: id=%s tier=%s status=%s\n", row["tenant_id"], row["tier"], row["status"])
    else:
        fail("Tenant database verification failed: record not found")

def build_kubernetes_stack(tenant, tier, db_url):
    """Builds typed Kubernetes resources for the tenant environment."""
    ns_name = "tenant-" + tenant
    
    # 1. Isolated Tenant Namespace
    ns = k8s.obj.namespace(
        name=ns_name,
        labels={
            "platform.corp/tenant": tenant,
            "platform.corp/tier": tier,
            "platform.corp/managed-by": "starkite",
        },
    )

    # 2. ConfigMap binding app configuration to the provisioned database
    cm = k8s.obj.config_map(
        name=tenant + "-config",
        namespace=ns_name,
        data={
            "TENANT_ID": tenant,
            "SERVICE_TIER": tier,
            "DATABASE_URL": db_url,
            "ENABLE_AUDIT": "true" if tier == "enterprise" else "false",
        },
    )

    # 3. Workload Deployment with container configuration
    replicas = 3 if tier == "enterprise" else 1
    dep = k8s.obj.deployment(
        name=tenant + "-api",
        namespace=ns_name,
        replicas=replicas,
        containers=[
            k8s.obj.container(
                name="api",
                image="ghcr.io/project-starkite/sample-app:v1.0.0",
                ports=[k8s.obj.container_port(container_port=8080, name="http")],
                env_from=[k8s.obj.env_from(config_map_ref={"name": tenant + "-config"})],
                resources=k8s.obj.resource_requirements(
                    requests={"cpu": "100m", "memory": "128Mi"},
                    limits={"cpu": "500m", "memory": "512Mi"},
                ),
            ),
        ],
        labels={
            "app": tenant + "-api",
            "platform.corp/tenant": tenant,
        },
    )

    return [ns, cm, dep]

def main():
    tenant = var_str("tenant", "acme")
    tier = var_str("tier", "standard")
    db_driver = var_str("db.driver", "sqlite")
    db_dsn = var_str("db.dsn", ":memory:")
    mode = var_str("mode", "manifest")  # "manifest" or "apply"

    printf("\n=== Starkite Platform Tenant Provisioner ===\n")
    printf("Target Tenant : %s\n", tenant)
    printf("Service Tier  : %s\n", tier)
    printf("Operation Mode: %s\n\n", mode)

    # Phase 1: The Multi-Protocol Last Mile (SQL Schema Migration & Seeding)
    run_last_mile_db_migration(db_driver, db_dsn, tenant, tier)

    # Phase 2: Assemble Kubernetes Infrastructure Stack
    printf("[Step 2/3] Constructing typed Kubernetes resources...\n")
    resources = build_kubernetes_stack(tenant, tier, db_dsn)
    printf("[Step 2/3 SUCCESS] Built %d Kubernetes resources (Namespace, ConfigMap, Deployment).\n", len(resources))

    # Phase 3: Delivery (Manifest Generation vs Direct In-Cluster Apply)
    if mode == "apply":
        printf("[Step 3/3] Applying resources directly to Kubernetes cluster...\n")
        k8s.apply(resources)
        printf("[Step 3/3 SUCCESS] All resources synchronized via Server-Side Apply.\n")
    else:
        printf("[Step 3/3] Generating multi-document YAML manifests:\n\n")
        # Multi-document YAML output for GitOps or piping to kubectl
        print(k8s.yaml(resources))

    printf("\n=== Provisioning Complete for %s ===\n\n", tenant)
