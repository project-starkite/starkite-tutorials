#!/usr/bin/env kite

load("./init_lock_bootstrap.star", "init_lock_bootstrap")

def test_build_dsn_and_lease():
    dsn = init_lock_bootstrap.build_dsn("postgres.init-lock-demo.svc.cluster.local", "5432", "postgres", "postgres", "payments")
    assert_equal(dsn, "postgres://postgres:postgres@postgres.init-lock-demo.svc.cluster.local:5432/payments?sslmode=disable")

    lease = init_lock_bootstrap.build_lease(
        "init-lock-demo",
        "payment-api-migration",
        "payment-api-abc-1",
        60,
        "2026-11-12T01:00:00.000000Z",
    )
    assert_equal(lease["apiVersion"], "coordination.k8s.io/v1")
    assert_equal(lease["kind"], "Lease")
    assert_equal(lease["spec"]["holderIdentity"], "payment-api-abc-1")
    assert_equal(lease["spec"]["leaseDurationSeconds"], 60)

def test_evaluate_lease_active_peer_and_expiry():
    lease = init_lock_bootstrap.build_lease(
        "init-lock-demo",
        "payment-api-migration",
        "payment-api-pod-1",
        30,
        "2026-11-12T01:00:00.000000Z",
    )

    active_now = time.parse("2026-11-12T01:00:10Z")
    held = init_lock_bootstrap.evaluate_lease(lease, "payment-api-pod-2", active_now)
    assert_false(held["can_acquire"])
    assert_equal(held["holder"], "payment-api-pod-1")
    assert_equal(held["reason"], "held_by_peer")

    expired_now = time.parse("2026-11-12T01:00:45Z")
    expired = init_lock_bootstrap.evaluate_lease(lease, "payment-api-pod-2", expired_now)
    assert_true(expired["can_acquire"])
    assert_equal(expired["transitions"], 1)
    assert_equal(expired["reason"], "expired")

def test_evaluate_lease_completed_blocks_reelection():
    lease = init_lock_bootstrap.build_lease(
        "init-lock-demo",
        "payment-api-migration",
        "payment-api-pod-1",
        30,
        "2026-11-12T01:00:00.000000Z",
    )
    lease["metadata"]["annotations"]["migration.starkite.io/version"] = "1"
    lease["metadata"]["annotations"]["migration.starkite.io/status"] = "completed"

    later = time.parse("2026-11-12T02:00:00Z")
    done = init_lock_bootstrap.evaluate_lease(lease, "payment-api-pod-2", later)
    assert_false(done["can_acquire"])
    assert_equal(done["completed_version"], 1)
    assert_equal(done["reason"], "completed")

def test_has_migration_version():
    assert_false(init_lock_bootstrap.has_migration_version([], 1))
    assert_false(init_lock_bootstrap.has_migration_version([{"version": 0}], 1))
    assert_true(init_lock_bootstrap.has_migration_version([{"version": 1}], 1))
    assert_true(init_lock_bootstrap.has_migration_version([{"version": 1}, {"version": 2}], 2))
