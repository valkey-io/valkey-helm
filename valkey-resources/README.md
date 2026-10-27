# valkey-resources

![Version: 0.4.0](https://img.shields.io/badge/Version-0.4.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v0.8.0](https://img.shields.io/badge/AppVersion-v0.8.0-informational?style=flat-square)

Deploys a single operator managed `ValkeyCluster`. Does not install the operator.

## Prerequisites

* Kubernetes 1.31+
* Helm 3.5+
* [valkey-operator](../valkey-operator/) **v0.8.0+** installed (CRDs present)

Without matching CRDs the API server rejects `ValkeyCluster` on apply. Helm does not upgrade CRDs for you; apply the operator chart CRDs when moving to v0.8.0. See [CHANGELOG.md](CHANGELOG.md) and the operator [v0.8.0](https://github.com/valkey-io/valkey-operator/releases/tag/v0.8.0) notes.

## Install

```bash
helm install valkey-operator valkey/valkey-operator \
  -n valkey-operator-system --create-namespace

helm install my-cluster valkey/valkey-resources -n valkey
```

### Examples

Copy-paste values for common shapes live under [`examples/`](examples/) (operator v0.6.0+). Start with `minimal.yaml` and `scheduling-node-spread.yaml` for production node HA via `scheduling.node.spread`. See [`examples/README.md`](examples/README.md).

```bash
helm install my-cluster ./valkey-resources -n valkey \
  -f valkey-resources/examples/scheduling-node-spread.yaml
```

Further examples and helm unittest render smoke for that directory are planned as a follow-up.

## Configuration

`cluster.spec` is a drop-in for `ValkeyCluster.spec` (any CRD field). Nested under `cluster` so future CR kinds can sit beside it without a generic top-level `spec`.

String values in `cluster.spec`, `cluster.labels`, and `cluster.annotations` are run through Helm `tpl`, so you can reference release metadata or `extraValues`:

```yaml
extraValues:
  tlsSecret: my-shared-tls

cluster:
  spec:
    shards: 3
    replicas: 1
    networking:
      tls:
        certificates:
          server:
            secretName: "{{ .Values.extraValues.tlsSecret }}"
```

### `cluster.spec` scheduling and PDB shape (since operator v0.4.0)

Placement and PDB fields changed in the CRD. Use the nested forms in values:

```yaml
cluster:
  spec:
    shards: 3
    replicas: 1
    podDisruptionBudget:
      mode: Cluster   # or Disabled
    scheduling:
      priorityClassName: high-priority
      node:
        spread:
          shard:
            mode: Required    # same-shard pods not co-located (anti-affinity)
          primaries:
            mode: Preferred
          pods:
            mode: Disabled
```

See [values.yaml](values.yaml), [CHANGELOG.md](CHANGELOG.md), and the [ValkeyCluster API](https://github.com/valkey-io/valkey-operator/blob/main/docs/valkeycluster.md).

| Parameter | Description | Default |
|---|---|---|
| `cluster.spec.shards` | Shard groups | `3` |
| `cluster.spec.replicas` | Replicas per shard | `1` |
| `extraValues` | Free-form map for use inside `tpl` strings | `{}` |
| `metrics.podMonitor.enabled` | Create a PodMonitor for ValkeyNode exporter sidecars (Prometheus Operator CRDs) | `false` |
| `metrics.podMonitor.port` | Scrape port name on the exporter container | `metrics` |
| `fullnameOverride` | ValkeyCluster name | release name |
| `nameOverride` | `app.kubernetes.io/name` label | chart name |

### Naming

The ValkeyCluster is named after the release, or `fullnameOverride` when set. The operator prefixes what it creates with `valkey-`, so `helm install cache ...` gives the ValkeyCluster `cache`, the headless Service `valkey-cache` and pods `valkey-cache-<shard>-<node>-0`. The other objects this chart renders use the same name.

The operator's CRD rejects names its workloads cannot carry: with StatefulSets and single-digit shard and replica indexes, 41 characters. When this chart is a subchart, the release name is the parent's. Under an alias the name becomes `<release>-<alias>`, so a parent can depend on the chart more than once (for example as `cache` and `sessions`). Without an alias, set `fullnameOverride` to keep the names apart from the parent's objects.

Releases installed before this change usually have a ValkeyCluster named `<release>-valkey-resources`; check the current name with `kubectl get valkeycluster -n <namespace>` and see [UPGRADE.md](UPGRADE.md) before upgrading them.

### Metrics (PodMonitor)

Operator pods run a `metrics-exporter` sidecar (port name `metrics`, 9121) when `cluster.spec.exporter` is enabled (operator default). This chart can create a **PodMonitor** that selects pods with `valkey.io/cluster=<ValkeyCluster name>` in the release namespace:

```yaml
metrics:
  podMonitor:
    enabled: true
    labels:
      release: prometheus
```

Use PodMonitor (not ServiceMonitor): node metrics are on pods, not a dedicated Service. Operator controller metrics stay on the `valkey-operator` chart ServiceMonitor.

### NetworkPolicy

Set `networkPolicy.enabled: true` to render a NetworkPolicy named after the ValkeyCluster. It selects pods with `valkey.io/cluster=<ValkeyCluster name>` and admits only what the cluster needs to run:

- the cluster's own pods on the `client` (6379) and `cluster-bus` (16379) ports
- the operator on the `client` port, so it can reconcile (`networkPolicy.operator`, default: pods labelled `app.kubernetes.io/name: valkey-operator` in any namespace)

With `metrics.podMonitor.enabled: true` it also admits the exporter port (`metrics.podMonitor.port`, default `metrics`, 9121) from any source, so Prometheus can scrape, as the valkey chart does with `metrics.enabled`. To narrow that, scrape some other way and admit the scraper through `extraIngress`.

`networkPolicy.allowExternal: true` also admits clients on the `client` port from any source. It defaults to `false`, unlike the valkey chart, so the policy admits nothing beyond the cluster until you add rules.

Egress is open by default (`networkPolicy.allowExternalEgress: true`, as in the valkey chart). With `allowExternalEgress: false` egress is limited to the cluster's own pods on `client` and `cluster-bus` and to UDP and TCP 53 in `networkPolicy.dnsNamespace` (default `kube-system`). On clusters with NodeLocal DNSCache, pods resolve through a node-local address (commonly `169.254.20.10`) that this rule does not cover; admit it with `extraEgress`:

```yaml
networkPolicy:
  allowExternalEgress: false
  extraEgress:
    - to:
        - ipBlock:
            cidr: 169.254.20.10/32
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

Everything else, including your clients, goes in `extraIngress` and `extraEgress`. Both are lists of NetworkPolicy rules appended as they are and templated with `tpl`:

```yaml
networkPolicy:
  enabled: true
  extraIngress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: "{{ .Release.Namespace }}"
      ports:
        - port: client
          protocol: TCP
  extraEgress: []
```

Rules use the operator's named container ports, `client`, `cluster-bus` and `metrics`, so they follow the pods if the port numbers change. The CNI must support named ports in NetworkPolicy (Calico and Cilium do).

Set `networkPolicy.operator: null` to drop the operator rule. An empty map does not drop it: Helm merges `{}` into the default peer, which then still renders. Helm merges overrides into the default peer, so to replace it set the default's `namespaceSelector` or `podSelector` key to null alongside your own.

`extraIngress` and `extraEgress` add rules on top; Kubernetes admits a connection if any rule matches, so they can only widen what the policy allows. They are lists, so a later values file replaces them whole. `networkPolicy.labels` and `networkPolicy.annotations` go on the policy object. The policy only has an effect when the CNI enforces NetworkPolicy. See [examples/network-policy.yaml](examples/network-policy.yaml).

### Users Secret

The operator reads ACL user passwords from the Secret `<ValkeyCluster name>-users` unless `cluster.spec.users[].passwordSecret.name` is set. The data key defaults to the username. The chart can render that Secret:

```yaml
usersSecret:
  create: true
  passwords:
    alice: change-me
```

| Value | Description | Default |
|---|---|---|
| `usersSecret.create` | Render the Secret | `false` |
| `usersSecret.name` | Secret name. Users without `passwordSecret.name` are pointed at it | `<fullname>-users` |
| `usersSecret.annotations` | Annotations on the Secret | `{}` |
| `usersSecret.passwords` | Map of username to password. Each key becomes a data key. Values must be strings | `{}` |

Passwords must be strings. YAML reads unquoted values such as `0123`, `1.10`, `on` or very long digit strings as numbers or booleans and changes them before the chart sees them (`0123` becomes `83`), so the schema rejects them: quote them, or pass them with `--set-string`. `usersSecret.name` may use templates. The render fails when `passwords` is empty, when a password is an empty string, or when a user in `cluster.spec.users` reads a key that `passwords` does not have. A user reads the key named after it, or each key in its `passwordSecret.keys`. Users the operator reads no password for (`nopass: true`, `resetpass: true` or `enabled: false`), and users whose `passwordSecret.name` names another Secret, are not checked. When `usersSecret.name` is set, the chart sets `passwordSecret.name` on every other user that does not set it. Passwords in values files are stored in plain text in the release, so supply them from a secrets tool rather than committing them. See [examples/users-secret.yaml](examples/users-secret.yaml).

To use a Secret you manage yourself, leave `usersSecret.create: false` and set `cluster.spec.users[].passwordSecret.name` (see [examples/users-acl.yaml](examples/users-acl.yaml)).

**Release model:** one logical workload per Helm release. v0.1 only renders `ValkeyCluster`. When more kinds land, the chart will keep that model (enable the kinds you need for that one workload; multiple independent clusters remain multiple releases).

### ServiceAccount

Set `serviceAccount.create: true` to render a ServiceAccount (named `serviceAccount.name`, default the chart fullname) and run the Valkey pods as it. The operator reads `spec.serviceAccountName` (operator v0.8.0+) and the ServiceAccount must exist in the release namespace before the pods start. Helm installs it first.

```yaml
serviceAccount:
  create: true
  annotations:
    example.com/role: reader
```

| Value | Description | Default |
|-------|-------------|---------|
| `serviceAccount.create` | Render the ServiceAccount | `false` |
| `serviceAccount.name` | ServiceAccount name | chart fullname |
| `serviceAccount.annotations` | Annotations on the ServiceAccount | `{}` |
| `serviceAccount.labels` | Labels on the ServiceAccount, merged over the chart labels | `{}` |
| `serviceAccount.automount` | Mount the API token into pods | `false` |

Wiring: when `serviceAccount.create` is true or `serviceAccount.name` is set, and `cluster.spec` has no `serviceAccountName`, the chart sets `spec.serviceAccountName` to the ServiceAccount name. An explicit `cluster.spec.serviceAccountName` always wins. With `create: true` it must name the chart's ServiceAccount, otherwise the render fails, because the created ServiceAccount would go unused. Set only `serviceAccount.name` (with `create: false`) to use a ServiceAccount that already exists.

Kubernetes decides whether to mount the API token when a pod is created, so a change to `serviceAccount.automount` reaches the Valkey pods only once they are recreated. The operator does not roll them for it.

### Extra objects

`extraObjects` renders additional Kubernetes objects with the release, for example a ConfigMap or Secret that `cluster.spec` references. It is a map so each key can be overridden or removed per environment. Each value is an object or a multi-line string, and is rendered through Helm `tpl` with the root context. Set a key to `null` to drop an entry inherited from another values file. Entries render in key order. No namespace is injected, so set `metadata.namespace` when the object must live elsewhere.

```yaml
extraObjects:
  settings:
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: '{{ include "valkey-resources.fullname" . }}-settings'
    data:
      release: '{{ .Release.Name }}'
```

An object entry is converted to YAML first and then rendered, so a template inside a quoted value is substituted inside those quotes. If the value can contain a quote character, as in `o'neil`, the result is invalid YAML. Use the string form for such values and quote them in the template with `quote`, which escapes quote characters (`squote` does not):

```yaml
extraObjects:
  owner: |
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: '{{ include "valkey-resources.fullname" . }}-owner'
    data:
      owner: {{ .Values.extraValues.owner | quote }}
```

See [`examples/extra-objects.yaml`](examples/extra-objects.yaml).

## Uninstall

```bash
helm uninstall my-cluster -n valkey
```

Deletes the ValkeyCluster. Child objects are garbage collected by the operator.
PVCs follow the cluster persistence reclaim policy.

## Related charts

| Chart | Role |
|---|---|
| [valkey](../valkey/) | Standalone/replication without operator |
| [valkey-operator](../valkey-operator/) | Installs the operator |
| **valkey-resources** | Operator managed CRs |
