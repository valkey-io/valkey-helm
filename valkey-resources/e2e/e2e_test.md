# End-to-end tests for `valkey-resources`

These tests install the `valkey-operator` and `valkey-resources` charts into a
local [kind](https://kind.sigs.k8s.io/) cluster, assert that the resulting
`ValkeyCluster` converges to a healthy topology, run a data round-trip against
a live node, and confirm that everything is garbage collected on uninstall.

Everything is driven by the `Makefile` in this directory. All paths are relative
to it, so **run the targets from `valkey-resources/e2e/`**.

## Prerequisites

- `kind`
- `kubectl`
- `helm`
- `docker`, with the daemon running

The `preflight` target checks all four before anything else runs.

## Quick start

```sh
cd valkey-resources/e2e
make e2e
```

`make e2e` runs the full suite and, if any step fails, dumps diagnostics before
exiting non-zero. Use `make test` instead if you would rather see the failing
step's own error without a large dump after it.

On a machine where the kind cluster and operator already exist the suite takes
a few seconds. A cold run is dominated by `kind create cluster` and image pulls.

## What the suite does

`make test` runs these targets in order:

| Target | What it asserts |
| --- | --- |
| `preflight` | `kind`, `kubectl`, `helm`, `docker` are on `PATH` and the docker daemon responds |
| `lint` | `helm lint` passes on the chart |
| `kind-up` | The kind cluster exists, creating it if not (idempotent) |
| `operator-install` | `valkey-operator` installs and becomes ready |
| `crd-check` | `valkeyclusters.valkey.io` and `valkeynodes.valkey.io` are registered |
| `resources-install` | The chart under test installs with `--wait` |
| `wait-ready` | The `ValkeyCluster` reaches `status.state=Ready` |
| `verify-topology` | `readyShards` equals `spec.shards`, the `ValkeyNode` count equals `shards x (1 + replicas)`, and every pod is `Ready` |
| `smoke` | `CLUSTER INFO` reports `cluster_state:ok`, and a `SET`/`GET` round-trip succeeds |
| `uninstall-check` | After `helm uninstall`, all `ValkeyNode`s and pods are garbage collected |

Targets outside the chain:

| Target | Purpose |
| --- | --- |
| `e2e` | Runs `test`, then `diagnostics` on failure |
| `diagnostics` | Best-effort dump for triage. Never fails |
| `template` | Renders the chart locally, no cluster needed |
| `kind-down` | Deletes the kind cluster |

## Configuration

Every knob is a `?=` variable, so override it on the command line:

```sh
make e2e VALUES=../examples/persistence.yaml
make e2e NAMESPACE=my-ns RELEASE=my-release
make diagnostics LOG_LINES=2000
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLUSTER_NAME` | `valkey-e2e` | kind cluster name |
| `NAMESPACE` | `valkey-e2e` | Namespace for the chart under test |
| `RELEASE` | `valkey-e2e` | Helm release name |
| `VALUES` | `../examples/minimal.yaml` | Values file for the chart under test |
| `TIMEOUT` | `5m` | Timeout for `helm --wait` and `kubectl wait` |
| `OPERATOR_NS` | `valkey-operator` | Namespace for the operator |
| `CRDS` | both Valkey CRDs | Names checked by `crd-check` |
| `SMOKE_KEY` / `SMOKE_VAL` | `e2e:smoke` / `hello-e2e` | Key and value for the round-trip |
| `GC_TIMEOUT` | `120` | Seconds `uninstall-check` polls for GC |
| `LOG_LINES` | `200` | `--tail` for `diagnostics` log dumps |
| `TOOLS` | the four binaries | Checked by `preflight` |

Running against a non-kind cluster works if you skip `kind-up` and point your
kubeconfig where you want it. Run the individual targets rather than `test`.

## Implementation notes

Things that are non-obvious and worth knowing before you change them.

**The `ValkeyCluster` name is discovered, not constructed.** It comes from the
chart's fullname template (`<release>-valkey-resources`), so the targets read
`.items[0].metadata.name` instead of assuming it. This also means the assertions
only cover the first `ValkeyCluster` in the namespace.

**`valkey.io/cluster` is the selector** used to scope `ValkeyNode` counts and pod
waits. It is present on both `ValkeyNode`s and pods, so the counts do not pick up
unrelated workloads sharing the namespace.

**`wait-ready` uses `--for=jsonpath`, not `--for=condition`.** `.status.state` is
the field the operator drives, with values `Initializing`, `Reconciling`, `Ready`,
`Degraded`, `Failed`. Note that `--for=jsonpath` does not fail fast: a cluster that
settles into `Failed` will block for the full `TIMEOUT`.

**`smoke` unsets `VALKEYCLI_AUTH` before invoking `valkey-cli`.** The server
container ships that variable set, but the default example has auth disabled, so
`valkey-cli` sends an `AUTH` the server rejects. `CLUSTER INFO` survives it, but
`SET` fails outright. If you add a test using an auth-enabled values file such as
`../examples/users-acl.yaml`, that unset has to become conditional.

**`smoke` passes `-c` to `SET`/`GET`.** In cluster mode the key hashes to a slot
that may be owned by a different shard than the pod you exec into. Without `-c`
you get a `MOVED` error instead of a redirect.

**`uninstall-check` polls rather than using `kubectl wait --for=delete`.**
`helm uninstall --wait` only waits on resources Helm owns. `ValkeyNode`s and pods
are created by the operator through owner references, so their removal is
asynchronous garbage collection that Helm does not track. That gap is exactly what
this target covers.

**PVCs are not asserted on.** They are cleaned up with the default values, but
StatefulSet PVCs are often retained by design. If you add a test around
`../examples/persistence.yaml`, decide explicitly whether retention is a pass
or a failure and assert it.

## Troubleshooting

Dump cluster state at any time:

```sh
make diagnostics
```

This prints, in sections: `ValkeyCluster`s and their describe output,
`ValkeyNode`s and their describe output, pods and their describe output, namespace
events, operator logs, and per-pod `server` container logs. It never fails, so it
is safe to chain after a failing command.

Two caveats when reading the output. The operator logs at DEBUG, so the default
`LOG_LINES=200` covers only a few seconds of reconcile traffic on an idle cluster;
raise it when investigating something that happened a while ago. And
`kubectl get events` is bounded by the cluster's event TTL, one hour by default on
kind, so slow failures may have already aged out.

To inspect a broken cluster by hand, run the chain up to the failing step and stop:

```sh
make kind-up operator-install resources-install
kubectl get valkeyclusters,valkeynodes,pods -n valkey-e2e
```

Start over from scratch:

```sh
make kind-down && make e2e
```

## CI

```sh
cd valkey-resources/e2e && make e2e
```

`e2e` returns non-zero on failure after emitting the diagnostics dump, so the job
fails red and the log carries the evidence.

`kind-up` is idempotent and `uninstall-check` removes the release at the end, so
the suite is safe to re-run against a persistent cluster. The kind cluster and the
operator are deliberately left in place. Add `make kind-down` as a cleanup step if
your runner is not ephemeral.

## Extending

Add a target, then add it to both `.PHONY` and the `test` prerequisite list.

Existing targets are a reasonable starting shape: `verify-topology` shows reading
spec and status fields into shell variables and asserting on them, `smoke` shows
execing `valkey-cli` in a pod and comparing output, and `uninstall-check` shows
polling for a condition with a timeout. Failing assertions should print both the
observed and expected values, and dump the relevant `kubectl get` output before
exiting 1.

Recipes are single shell invocations with `set -eu`, so remember that every line
needs a trailing backslash and that `$` must be written `$$` to reach the shell.
