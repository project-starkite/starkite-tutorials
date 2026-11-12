# Sandboxed Kubernetes Init Containers with Starkite

Kubernetes `initContainers` run startup tasks to completion before the Kubelet starts any application container in a Pod. Production workloads rely on this phase for startup choreography that stays outside the main service binary: assembling dynamic configuration from cluster APIs, staging short-lived credentials onto shared volumes, checking upstream readiness, and recording cryptographic checksums for integrity verification. When an init container exits non-zero, Kubernetes halts the Pod rollout before a misconfigured container can accept traffic.

Starkite (`kite`) replaces ad-hoc shell scripts and multi-tool utility images in this startup phase with a single static binary built on `cgr.dev/chainguard/static` (`ghcr.io/project-starkite/starkite:v0.11.8`). The runtime embeds Starlark modules for Kubernetes API access (`k8s`), filesystem paths (`fs`), JSON serialization (`json`), and cryptographic digests (`hash`), confined under a default-deny kernel sandbox with no shell in the image.

In this tutorial, you will build a sandboxed init container for a `payment-api` service, run offline unit tests in milliseconds with `kite test`, generate the Kubernetes manifests in Starlark, verify the live rollout, and test rollout failure gating when required configuration is missing.

---

## Why Traditional Init Containers Fall Short

Suppose your `payment-api` Deployment needs an init container to read a `ConfigMap` named `payment-api-settings` in the `init-demo` namespace. Before the HTTP server starts, the init container must verify four required keys (`DB_HOST`, `DB_PORT`, `RATE_LIMIT_RPS`, and `TLS_MODE`), convert `DB_PORT` and `RATE_LIMIT_RPS` from strings to integers, write `/work/shared/runtime-config.json`, and record a SHA-256 checksum at `/work/shared/runtime-config.sha256`.

In a conventional Kubernetes manifest, engineers embed an inline `/bin/sh -c` script inside a utility image such as `alpine/k8s` to pipe output across `kubectl`, `jq`, and `sha256sum`:

```yaml
# Traditional POSIX sh + kubectl + jq init container
initContainers:
  - name: config-bootstrap
    image: alpine/k8s:1.32.2
    command: ["/bin/sh", "-c"]
    args:
      - |
        set -eu

        cm_json=$(kubectl -n init-demo get configmap payment-api-settings -o json)

        for key in DB_HOST DB_PORT RATE_LIMIT_RPS TLS_MODE; do
          if [ -z "$(printf '%s\n' "$cm_json" | jq -r ".data.${key} // empty")" ]; then
            echo "Missing required key ${key} in ConfigMap payment-api-settings" >&2
            exit 1
          fi
        done

        cd /work/shared
        printf '%s\n' "$cm_json" | jq -c '{
          service: "payment-api",
          namespace: "init-demo",
          database: {
            host: .data.DB_HOST,
            port: (.data.DB_PORT | tonumber),
            tls_mode: .data.TLS_MODE
          },
          limits: {
            rps: (.data.RATE_LIMIT_RPS | tonumber)
          }
        }' > runtime-config.json
        sha256sum runtime-config.json > runtime-config.sha256
    volumeMounts:
      - name: shared-config
        mountPath: /work/shared
```

Even for ~25 lines of bootstrap logic, this pattern introduces six operational problems in production clusters:

1. **Multi-Tool Image Bloat**: The node pulls an 80–250 MB utility image bundling an OS userland, `/bin/sh`, `kubectl`, `curl`, `jq`, and `coreutils` just to fetch one API object and write two small files. Larger images increase cold-start latency when autoscaling nodes.
2. **CVE Attack Surface**: Every shared C library, TLS package, and CLI binary in a general-purpose base image generates vulnerability findings that platform teams must triage, patch, and rebuild—even when the init script never calls those binaries.
3. **Fragile Shell Piping**: Passing JSON payloads through shell variable expansions (`$cm_json`), `printf`, and `jq` filters breaks when configuration strings contain quotes, backslashes, or multiline values.
4. **Non-Deterministic Error Handling**: POSIX `sh` lacks `pipefail` in many minimal shells and can mask non-zero exit codes inside command substitutions. Type conversion errors such as `tonumber` in `jq` surface only at Pod startup as unstructured stderr text.
5. **Unconfined Container Userlands**: Dropping Linux capabilities in `securityContext` still leaves `/bin/sh`, `curl`, and `kubectl` executable inside the container, with read access across the container rootfs, projected credentials, and ambient environment variables.
6. **No Local Unit Testing**: Inline shell scripts buried inside YAML manifests cannot be imported as functions or unit-tested offline. Checking edge cases—such as an empty string versus a missing key—requires deploying to a live cluster on every change.

Starkite eliminates these failure modes by replacing the OS userland and external CLI binaries with built-in Starlark modules, kernel-level sandboxing, and an offline test runner:

| Operational Dimension | Shell + Utility Image (`alpine/k8s`) | Python + `kubernetes` SDK Image | Starkite (`ghcr.io/project-starkite/starkite:v0.11.8`) |
| :--- | :--- | :--- | :--- |
| **Container Base Image** | 80–250 MB OS layer + `kubectl`, `curl`, `jq` | 120–300 MB OS layer + Python + `pip` packages | Single minimal static binary on `cgr.dev/chainguard/static` |
| **Shell & Binary Surface** | Ships `/bin/sh`, `coreutils`, and network CLIs | Ships shell, Python interpreter, and C libraries | Zero shell (`/bin/sh` does not exist in the image) |
| **Kubernetes API Client** | Spawns `kubectl` or `curl` subprocesses | External `kubernetes` package + dependency tree | Built-in `k8s` module with `InClusterConfig` |
| **Config & Hash Primitives** | Pipes text across `jq` and `sha256sum` | Separate `json`, `pathlib`, and `hashlib` imports | Built-in `fs`, `json`, and `hash` modules |
| **Error Handling** | `set -eu` exit codes and raw stderr text | Uncaught runtime exceptions and tracebacks | Deterministic types and fail-fast `fail(...)` |
| **Offline Unit Testing** | Manual cluster deploys or `bats` harnesses | Requires `pytest` and virtualenv setup | Sub-millisecond function eval via `kite test` (<10ms CLI run) |
| **Process Confinement** | Unconfined container filesystem, network, and env | Unconfined container filesystem, network, and env | Kernel-level path/network sandbox + zero-trust env scrubbing |

---

## Architecture and Pod Startup Lifecycle

Inside a Pod, the Kubelet executes `initContainers` sequentially and starts the main `containers` only after every init container exits `0`. In this deployment, both the `config-bootstrap` init container and the `payment-api` application container run `ghcr.io/project-starkite/starkite:v0.11.8`, exchanging validated configuration through an in-Pod `emptyDir` volume (`shared-config`).

```mermaid
sequenceDiagram
    participant Kubelet as Kubelet
    participant Init as initContainer: config-bootstrap
    participant API as Kubernetes API Server
    participant Vol as emptyDir Volume (shared-config)
    participant App as Main Container: payment-api (:8080)

    Kubelet->>Init: kite run /scripts/init_bootstrap.star
    Note over Init: Enforce zero-trust sandbox (paths, net, env allowlist)
    Init->>API: k.get("configmap", "payment-api-settings")
    API-->>Init: Return ConfigMap data
    Init->>Init: validate_keys(), render_config(), hash.text().sha256()
    Init->>Vol: Write /work/shared/runtime-config.json & runtime-config.sha256
    Init-->>Kubelet: Exit 0
    Kubelet->>App: kite eval <server.star>
    App->>Vol: Read /etc/payment-api/runtime-config.json & runtime-config.sha256
    Note over App: Print config & SHA-256 digest, serve HTTP on :8080
```

### Zero-Trust Sandbox Confinement

When `kite run` starts inside `config-bootstrap`, Starkite begins under the `deny-all` profile. Filesystem paths, network sockets, subprocess execution, and environment variables remain blocked unless explicitly granted via CLI flags:

- `--sandbox-path-read=/scripts`: Allows reading `init_bootstrap.star` from the read-only `ConfigMap` volume mount.
- `--sandbox-path-read=/var/run/secrets/kubernetes.io/serviceaccount`: Allows `k8s.config()` to read the Pod's projected ServiceAccount token and cluster `ca.crt`.
- `--sandbox-path-write=/work/shared`: Restricts filesystem writes exclusively to the `shared-config` `emptyDir` mount where `runtime-config.json` and `runtime-config.sha256` are created.
- `--sandbox-net-allow`: Permits outbound HTTPS connections to the Kubernetes API server.
- `--env=KUBERNETES_SERVICE_HOST` and `--env=KUBERNETES_SERVICE_PORT`: Forwards only the two discovery variables required by `InClusterConfig`, scrubbing all other ambient container environment variables before the script executes.

After `config-bootstrap` exits `0`, the `payment-api` container mounts that same `shared-config` volume read-only at `/etc/payment-api` (`readOnly: true`) with `--sandbox-path-read=/etc/payment-api` and `--sandbox-net-allow`. The running HTTP server cannot modify its bootstrapped configuration, inspect the Pod's ServiceAccount token, or spawn a subprocess.

---

## Prerequisites and Companion Files

Before running the steps below, ensure you have:

1. **Starkite CLI (`kite`)**: Installed in your `PATH` (`kite version`). See the [root README](../../README.md#installation) for installation instructions.
2. **Kubernetes Cluster & `kubectl`**: An active cluster (`kind`, `k3s`, `minikube`, or remote) configured in `~/.kube/config`.

Change into the tutorial directory:

```bash
cd /home/alice/projects/starkite-tutorials/k8s/init-cluster
```

All files for this tutorial reside in [`k8s/init-cluster/`](./):

| File | Purpose |
| :--- | :--- |
| [`init_bootstrap.star`](./init_bootstrap.star) | Sandboxed init container script that fetches the `ConfigMap`, validates required keys, writes typed JSON, and records a SHA-256 checksum. |
| [`init_bootstrap_test.star`](./init_bootstrap_test.star) | Offline unit test suite executed with `kite test` to verify key validation and configuration rendering without a cluster. |
| [`server.star`](./server.star) | HTTP application script executed in the main container to log the configuration and serve it on port `8080`. |
| [`manifest.star`](./manifest.star) | Starlark manifest generator that builds the Namespace, RBAC, ConfigMaps, and Deployment as multi-document YAML. |
| [`manifest.yaml`](./manifest.yaml) | Pre-rendered Kubernetes manifest ready for `kubectl apply -f ./manifest.yaml`. |
| [`verify.star`](./verify.star) | Live cluster verifier that polls Deployment readiness, reads Pod logs, and asserts SHA-256 digest integrity. |

---

## Step 1: Write the Init Script (`init_bootstrap.star`)

Structure the bootstrap script so pure validation and rendering functions (`validate_keys` and `render_config`) stay separate from Kubernetes API and filesystem calls in `main()`. Keeping validation logic free of cluster I/O makes every rule directly testable offline.

Inspect [`init_bootstrap.star`](./init_bootstrap.star):

```python
#!/usr/bin/env kite

REQUIRED_KEYS = ["DB_HOST", "DB_PORT", "RATE_LIMIT_RPS", "TLS_MODE"]

def validate_keys(data):
    return [k for k in REQUIRED_KEYS if not data.get(k)]

def render_config(ns, data):
    return {
        "service": "payment-api",
        "namespace": ns,
        "database": {
            "host": data["DB_HOST"],
            "port": int(data["DB_PORT"]),
            "tls_mode": data["TLS_MODE"],
        },
        "limits": {
            "rps": int(data["RATE_LIMIT_RPS"]),
        },
    }

def main():
    ns = var_str("namespace", "init-demo")
    out = fs.path(var_str("out.dir", "/work/shared"))

    k = k8s.config(namespace=ns)
    cm = k.get("configmap", "payment-api-settings")

    data = cm.get("data", {})
    missing = validate_keys(data)
    if missing:
        fail("missing required keys: %s" % ", ".join(missing))

    payload = json.encode(render_config(ns, data))
    out.mkdir(parents=True)
    (out / "runtime-config.json").write_text(payload)
    (out / "runtime-config.sha256").write_text(hash.text(payload).sha256() + "  runtime-config.json\n")
```

Each part of the script handles one startup responsibility:

- **Key Validation (`validate_keys`)**: Checks all four entries in `REQUIRED_KEYS`. Evaluating `not data.get(k)` catches both omitted keys and keys set to an empty string `""`.
- **Typed Rendering (`render_config`)**: Kubernetes `ConfigMap` entries are always stored as strings. Converting `int(data["DB_PORT"])` and `int(data["RATE_LIMIT_RPS"])` during initialization catches non-numeric values before the main container starts.
- **In-Cluster Client (`k8s.config` & `k.get`)**: When running inside a Pod, `k8s.config(namespace=ns)` loads the mounted ServiceAccount credentials (`InClusterConfig`) automatically and retrieves `payment-api-settings` from the API server.
- **Fail-Fast Exit (`fail`)**: If any required key is missing, `fail(...)` terminates the process immediately with a non-zero exit code and prints the missing key names to stderr.
- **JSON Output & Checksum (`json.encode` & `hash.text`)**: Encodes the dictionary to JSON, writes `runtime-config.json` into `/work/shared`, and writes a `sha256sum`-compatible digest file (`<digest>  runtime-config.json\n`).

---

## Step 2: Unit-Test Offline (`init_bootstrap_test.star`)

Before building manifests or touching a cluster, verify `validate_keys` and `render_config` locally with `kite test`. The test runner loads `./init_bootstrap.star` as a Starlark module and executes every `test_*` function in memory.

Inspect [`init_bootstrap_test.star`](./init_bootstrap_test.star):

```python
#!/usr/bin/env kite

load("./init_bootstrap.star", "init_bootstrap")

SAMPLE_DATA = {
    "DB_HOST": "postgres.internal.svc.cluster.local",
    "DB_PORT": "5432",
    "RATE_LIMIT_RPS": "250",
    "TLS_MODE": "strict",
}

def test_validate_keys():
    assert_equal(init_bootstrap.validate_keys(SAMPLE_DATA), [])
    missing = init_bootstrap.validate_keys({"DB_HOST": "db", "TLS_MODE": ""})
    assert_equal(len(missing), 3)

def test_render_config():
    cfg = init_bootstrap.render_config("init-demo", SAMPLE_DATA)
    assert_equal(cfg["service"], "payment-api")
    assert_equal(cfg["database"]["port"], 5432)
    assert_equal(cfg["limits"]["rps"], 250)
```

Lint all Starlark files in the directory and run the unit test suite under `--sandbox-path-read=.`:

```bash
kite validate --lint *.star
kite test ./init_bootstrap_test.star --sandbox-path-read=.
```

```text
# (host-specific values differ)
init_bootstrap.star: OK
init_bootstrap_test.star: OK
manifest.star: OK
server.star: OK
verify.star: OK
Found 1 test file(s)
============================================================
Tests: 2 passed, 0 failed, 2 total
Time:  4ms
============================================================
```

`test_validate_keys` confirms both the happy path and partial data where `DB_PORT` and `RATE_LIMIT_RPS` are omitted while `TLS_MODE` is empty (`3` missing keys). `test_render_config` confirms string-to-integer conversion for `port` (`5432`) and `rps` (`250`) in milliseconds with zero network access.

---

## Step 3: Inspect the Application Server (`server.star`)

Once `config-bootstrap` finishes writing `/work/shared/runtime-config.json` and exits `0`, the Kubelet starts the `payment-api` container. Rather than requiring a separate language toolchain for this tutorial, `payment-api` runs [`server.star`](./server.star) via `kite eval` on the same Starkite image:

```python
#!/usr/bin/env kite

def main():
    cfg = fs.read_text("/etc/payment-api/runtime-config.json")
    sha = fs.read_text("/etc/payment-api/runtime-config.sha256")
    print(cfg)
    print(sha)
    http.serve({"GET /": lambda req: {"status": 200, "headers": {"Content-Type": "application/json"}, "body": cfg}}, port=8080)
```

At startup, `server.star` reads the rendered JSON file and its SHA-256 checksum from the read-only `/etc/payment-api` mount, logs both values to stdout so cluster tooling can audit them, and starts an HTTP server on port `8080` returning the configuration on `GET /`.

---

## Step 4: Generate Manifests and Deploy (`manifest.star` & `manifest.yaml`)

Maintaining inline scripts and RBAC bindings across raw YAML files introduces copy-paste drift when script files change. [`manifest.star`](./manifest.star) builds the full seven-resource Kubernetes stack (`Namespace`, `ServiceAccount`, `Role`, `RoleBinding`, settings `ConfigMap`, init-script `ConfigMap`, and `Deployment`) using typed `k8s.obj.*` constructors and reads [`init_bootstrap.star`](./init_bootstrap.star) and [`server.star`](./server.star) directly from disk via `fs.read_text()`:

```python
#!/usr/bin/env kite

def build_stack(
    app="payment-api",
    ns="init-demo",
    kite_image="ghcr.io/project-starkite/starkite:v0.11.8",
):
    sa = k8s.obj.service_account(name=app + "-sa", namespace=ns)
    role_name = app + "-config-reader"
    role = k8s.obj.role(
        name=role_name,
        namespace=ns,
        rules=[k8s.obj.policy_rule(api_groups=[""], resources=["configmaps"], verbs=["get", "list"])],
    )
    rb = k8s.obj.role_binding(
        name=role_name + "-binding",
        namespace=ns,
        role_ref={"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": role_name},
        subjects=[k8s.obj.subject(kind="ServiceAccount", name=sa, namespace=ns)],
    )
    settings_cm = k8s.obj.config_map(
        name=app + "-settings",
        namespace=ns,
        data={
            "DB_HOST": "postgres.internal.svc.cluster.local",
            "DB_PORT": "5432",
            "RATE_LIMIT_RPS": "250",
            "TLS_MODE": "strict",
        },
    )
    script_path = var_str("script", "./init_bootstrap.star")
    script_cm = k8s.obj.config_map(
        name=app + "-init-script",
        namespace=ns,
        data={"init_bootstrap.star": fs.read_text(script_path)},
    )
    server_script_path = var_str("server_script", "./server.star")

    init_container = k8s.obj.container(
        name="config-bootstrap",
        image=kite_image,
        args=[
            "run",
            "/scripts/init_bootstrap.star",
            "--sandbox-path-read=/scripts",
            "--sandbox-path-read=/var/run/secrets/kubernetes.io/serviceaccount",
            "--sandbox-path-write=/work/shared",
            "--sandbox-net-allow",
            "--env=KUBERNETES_SERVICE_HOST",
            "--env=KUBERNETES_SERVICE_PORT",
        ],
        volume_mounts=[
            k8s.obj.volume_mount(name="shared-config", mount_path="/work/shared"),
            k8s.obj.volume_mount(name="bootstrap-script", mount_path="/scripts", read_only=True),
        ],
    )

    app_container = k8s.obj.container(
        name=app,
        image=kite_image,
        command=["kite", "eval"],
        args=[
            fs.read_text(server_script_path),
            "--sandbox-path-read=/etc/payment-api",
            "--sandbox-net-allow",
        ],
        ports=[k8s.obj.container_port(container_port=8080, name="http")],
        volume_mounts=[
            k8s.obj.volume_mount(name="shared-config", mount_path="/etc/payment-api", read_only=True),
        ],
    )

    dep = k8s.obj.deployment(
        name=app,
        namespace=ns,
        labels={"app": app},
        replicas=2,
        service_account=sa,
        init_containers=[init_container],
        containers=[app_container],
        volumes=[
            k8s.obj.volume(name="shared-config", empty_dir=True),
            k8s.obj.volume(name="bootstrap-script", config_map=script_cm),
        ],
    )

    return [k8s.obj.namespace(name=ns), sa, role, rb, settings_cm, script_cm, dep]

def main():
    stack = build_stack(
        app=var_str("app", "payment-api"),
        ns=var_str("namespace", "init-demo"),
    )
    print(k8s.yaml(stack))
```

Notice how `k8s.yaml(stack)` handles multi-line script content when generating [`manifest.yaml`](./manifest.yaml). Instead of emitting JSON-escaped `\n` strings, `k8s.yaml` formats multi-line Starlark scripts—both inside `payment-api-init-script` and in the `args` list of `payment-api`—as standard YAML literal block scalars (`|`):

```yaml
      containers:
        - args:
            - |
              #!/usr/bin/env kite

              def main():
                  cfg = fs.read_text("/etc/payment-api/runtime-config.json")
                  sha = fs.read_text("/etc/payment-api/runtime-config.sha256")
                  print(cfg)
                  print(sha)
                  http.serve({"GET /": lambda req: {"status": 200, "headers": {"Content-Type": "application/json"}, "body": cfg}}, port=8080)
            - --sandbox-path-read=/etc/payment-api
            - --sandbox-net-allow
          command:
            - kite
            - eval
          image: ghcr.io/project-starkite/starkite:v0.11.8
          name: payment-api
```

Render [`manifest.yaml`](./manifest.yaml) and apply it to your cluster (or pipe directly with `kite run ./manifest.star --sandbox-path-read=. | kubectl apply -f -`):

```bash
kite run ./manifest.star --sandbox-path-read=. > ./manifest.yaml
kubectl apply -f ./manifest.yaml
```

```text
# (host-specific values differ)
namespace/init-demo created
serviceaccount/payment-api-sa created
role.rbac.authorization.k8s.io/payment-api-config-reader created
rolebinding.rbac.authorization.k8s.io/payment-api-config-reader-binding created
configmap/payment-api-settings created
configmap/payment-api-init-script created
deployment.apps/payment-api created
```

---

## Step 5: Verify the Live Deployment (`verify.star`)

[`verify.star`](./verify.star) automates post-deployment verification against the live cluster. It waits for the Deployment to report `Available`, reads the startup output logged by `payment-api`, recomputes the SHA-256 digest of the JSON payload, and asserts that it matches the checksum written by `config-bootstrap`:

```python
#!/usr/bin/env kite

def main():
    app = var_str("app", "payment-api")
    ns = var_str("namespace", "init-demo")

    k = k8s.config(namespace=ns, timeout="30s")

    ready = k.wait_for("deployment", app, condition="Available", timeout="60s")
    if not ready.ready:
        fail("deployment %s not available: %s" % (app, ready.message))

    pods = [p for p in k.list("pods", labels="app=" + app) if p.status.phase == "Running"]
    if not pods:
        fail("no running pods found for app=%s" % app)
    pod_name = pods[0].metadata.name

    app_lines = [l for l in k.logs(pod_name, container=app).strip().split("\n") if not l.startswith("sandbox:")]
    raw_json = app_lines[0]
    recorded_digest = app_lines[1].split(" ")[0]

    actual_digest = hash.text(raw_json).sha256()
    if actual_digest != recorded_digest:
        fail("digest mismatch: actual=%s recorded=%s" % (actual_digest, recorded_digest))

    parsed = json.decode(raw_json)

    tbl = table.new(["Check", "Target", "Result"])
    tbl.add_row("Deployment Readiness", "deployment/" + app, "AVAILABLE (%d pods)" % len(pods))
    tbl.add_row("Database Endpoint", "%s:%d" % (parsed["database"]["host"], int(parsed["database"]["port"])), "VERIFIED")
    tbl.add_row("Rate Limit (RPS)", str(int(parsed["limits"]["rps"])), "VERIFIED")
    tbl.add_row("SHA-256 Integrity", actual_digest[:16] + "...", "MATCHED")
    print(tbl.render().strip())
```

Run `verify.star` from your workstation, granting read access to the local directory and `~/.kube` along with outbound network access to your cluster API server:

```bash
kite run ./verify.star \
  --sandbox-path-read=. \
  --sandbox-path-read=$HOME/.kube \
  --sandbox-net-allow \
  --env=HOME
```

```text
# (host-specific values differ)
Check                | Target                                   | Result            
---------------------+------------------------------------------+-------------------
Deployment Readiness | deployment/payment-api                   | AVAILABLE (2 pods)
Database Endpoint    | postgres.internal.svc.cluster.local:5432 | VERIFIED          
Rate Limit (RPS)     | 250                                      | VERIFIED          
SHA-256 Integrity    | 6a06456e6644f130...                      | MATCHED
```

Both `payment-api` replicas completed initialization, parsed `DB_PORT` (`5432`) and `RATE_LIMIT_RPS` (`250`) into JSON integers, and served payloads matching the SHA-256 digest generated by `config-bootstrap`.

---

## Step 6: Simulate Configuration Failure Gating

An init container protects production rollouts when a bad configuration change lands in the cluster. Because Kubernetes holds main containers back until every `initContainer` exits `0`, `fail(...)` in `init_bootstrap.star` stops broken replacement Pods during a rolling update while existing healthy replicas stay online.

Remove the required `TLS_MODE` key from `payment-api-settings` and trigger a rolling restart:

```bash
kubectl -n init-demo patch configmap payment-api-settings --type=json \
  -p='[{"op": "remove", "path": "/data/TLS_MODE"}]'

kubectl -n init-demo rollout restart deployment/payment-api
```

Inspect the Pod status and the `config-bootstrap` init container logs:

```bash
kubectl -n init-demo get pods -l app=payment-api
kubectl -n init-demo logs payment-api-7b89f7f45c-k9x2w -c config-bootstrap
```

```text
# (host-specific values differ)
NAME                           READY   STATUS       RESTARTS   AGE
payment-api-5bb4c8f84d-d7mpb   1/1     Running      0          2m
payment-api-5bb4c8f84d-sglb8   1/1     Running      0          2m
payment-api-7b89f7f45c-k9x2w   0/1     Init:Error   0          8s

Error: script error: missing required keys: TLS_MODE
```

Observe how the rollout behaves:

- Both original Pods (`payment-api-5bb4c8f84d-*`) remain `1/1 Running` and continue serving HTTP traffic from their previously validated `emptyDir` configuration.
- The replacement Pod (`payment-api-7b89f7f45c-k9x2w`) halts in `Init:Error` inside `config-bootstrap`, preventing an unconfigured `payment-api` container from starting.
- Container logs report `Error: script error: missing required keys: TLS_MODE`, identifying the exact missing key without shell pipeline noise.

Re-apply [`manifest.yaml`](./manifest.yaml) to restore `TLS_MODE` and let the rollout finish cleanly:

```bash
kubectl apply -f ./manifest.yaml
kubectl -n init-demo rollout status deployment/payment-api
```

---

## Cleanup

Delete the `init-demo` namespace when finished to remove all Pods, RBAC bindings, ConfigMaps, and Deployments created in this tutorial:

```bash
kubectl delete namespace init-demo
```
