#!/usr/bin/env kite
"""Offline unit tests for edge_agent, setup, and teardown helpers."""

load("./edge_agent.star", "edge_agent")
load("./provision_fleet.star", "provision_fleet")
load("./setup.star", "setup")
load("./teardown.star", "teardown")

def test_site_selector_and_container_name():
    assert_equal(edge_agent.site_selector("site-a"), "edge.starkite.io/site=site-a")
    assert_equal(edge_agent.site_from_object({"metadata": {"labels": {"edge.starkite.io/site": "site-b"}}}), "site-b")
    assert_equal(edge_agent.container_name("site-a", "hello-web"), "edge-site-a-hello-web")
    assert_equal(edge_agent.container_name("store-04", "pos-api"), "edge-store-04-pos-api")

def test_format_host_ports():
    assert_equal(edge_agent.format_host_ports({}), "-")
    assert_equal(edge_agent.format_host_ports({"80/tcp": 18080}), "18080->80/tcp")
    assert_equal(
        edge_agent.format_host_ports({"443/tcp": 18443, "80/tcp": 18080}),
        "18443->443/tcp,18080->80/tcp",
    )

def test_extract_spec():
    obj = {
        "spec": {
            "image": "docker.io/library/nginx:1.27-alpine",
            "ports": {"80/tcp": 18080},
            "env": {"APP_SITE": "site-a"},
        },
    }
    spec = edge_agent.extract_spec(obj)
    assert_equal(spec["image"], "docker.io/library/nginx:1.27-alpine")
    assert_equal(spec["command"], [])
    assert_equal(spec["ports"], {"80/tcp": 18080})
    assert_equal(spec["env"], {"APP_SITE": "site-a"})

def test_build_status_and_status_matches():
    box = {
        "id": "a1b2c3d4e5f678901234567890abcdef",
        "name": "edge-site-a-hello-web",
        "status": "running",
        "image": "docker.io/library/nginx:1.27-alpine",
    }
    st = edge_agent.build_status(box, "site-a", "docker.io/library/nginx:1.27-alpine", {"80/tcp": 18080}, 2)
    assert_equal(st["site"], "site-a")
    assert_equal(st["phase"], "Running")
    assert_equal(st["containerId"], "a1b2c3d4e5f6")
    assert_equal(st["hostPort"], "18080->80/tcp")
    assert_equal(st["observedGeneration"], 2)
    assert_equal(st["conditions"][0]["status"], "True")

    assert_true(edge_agent.status_matches(st, st))
    changed = dict(st)
    changed["observedGeneration"] = 3
    assert_false(edge_agent.status_matches(st, changed))

def test_setup_retarget_manifest():
    ns_doc = {"kind": "Namespace", "metadata": {"name": "edge-fleet"}}
    setup.retarget_manifest(ns_doc, "retail-east")
    assert_equal(ns_doc["metadata"]["name"], "retail-east")

    rb_doc = {
        "kind": "RoleBinding",
        "metadata": {"name": "edge-agent-binding", "namespace": "edge-fleet"},
        "subjects": [{"kind": "ServiceAccount", "name": "edge-agent", "namespace": "edge-fleet"}],
    }
    setup.retarget_manifest(rb_doc, "retail-east")
    assert_equal(rb_doc["metadata"]["namespace"], "retail-east")
    assert_equal(rb_doc["subjects"][0]["namespace"], "retail-east")

def test_teardown_is_managed_container():
    assert_true(teardown.is_managed_container("edge-site-a-hello-web"))
    assert_true(teardown.is_managed_container("/edge-site-a-hello-web", "site-a"))
    assert_false(teardown.is_managed_container("edge-site-b-hello-web", "site-a"))
    assert_false(teardown.is_managed_container("kind-control-plane"))

def test_provision_fleet_helpers():
    assert_equal(provision_fleet.parse_hosts("edge-01, edge-02, ,edge-03"), ["edge-01", "edge-02", "edge-03"])
    assert_equal(provision_fleet.site_name_for_index(0), "site-1")
    assert_equal(provision_fleet.site_name_for_index(3), "site-4")

    cfg = provision_fleet.build_kubeconfig("https://10.0.0.10:6443", "LS0t", "tok-123", "edge-fleet")
    assert_true("server: https://10.0.0.10:6443" in cfg)
    assert_true("namespace: edge-fleet" in cfg)
    assert_true("token: tok-123" in cfg)

    cmd = provision_fleet.agent_launch_cmd("site-2", "edge-fleet", "10s")
    assert_true("--site=site-2" in cmd)
    assert_true("--poll=10s" in cmd)
    assert_true("--timeout=0" in cmd)
