# Contributing to the valkey-operator Helm Chart

Thanks for your interest in improving the `valkey-operator` Helm chart! This
guide walks you through everything you need to develop, validate, and submit
changes to the chart end to end.

This document covers the `valkey-operator` chart only. It packages the
[Valkey Operator](https://github.com/valkey-io/valkey-operator), which manages
`ValkeyCluster` resources. It is separate from the [valkey](../valkey/) chart,
which deploys Valkey instances directly.

## Getting Started

### Prerequisites

Install the following tools before you begin:

- [Helm](https://helm.sh/docs/intro/install/) 3.5+
- Kubernetes 1.20+ (a real cluster, or [kind](https://kind.sigs.k8s.io/) for local testing)
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/)
- [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) for local cluster validation
- [`helm-unittest`](https://github.com/helm-unittest/helm-unittest) for running the chart's unit tests:

  ```bash
  helm plugin install https://github.com/helm-unittest/helm-unittest
  ```

### Fork and clone the repository

First, fork [valkey-io/valkey-helm](https://github.com/valkey-io/valkey-helm)
to your own GitHub account using the **Fork** button, then clone your fork:

```bash
git clone https://github.com/<your-username>/valkey-helm.git
cd valkey-helm
```

Add the upstream repository as a remote so you can keep your fork in sync:

```bash
git remote add upstream https://github.com/valkey-io/valkey-helm.git
git fetch upstream
```

The commands below assume you run them from the repository root unless noted
otherwise.

## Development Workflow

### Branching

Never push directly to upstream. Create a feature branch from an up-to-date
`main` on your fork:

```bash
git checkout main
git pull upstream main
git checkout -b my-change
```

Push your branch to your fork and open the pull request against
`valkey-io/valkey-helm`.

### Make your changes

Most changes touch one or more of:

- `templates/` — the rendered Kubernetes manifests (Deployment, RBAC, NetworkPolicy, etc.)
- `values.yaml` — the chart's configurable parameters and their defaults
- `Chart.yaml` — chart metadata and version
- `crds/` — the `ValkeyCluster` and `ValkeyNode` CustomResourceDefinitions

When you add or change a configurable parameter, update both `values.yaml` and
the parameter table in [README.md](README.md) so the documentation stays in
sync.

### Render your changes

As you work, render the templates locally to confirm they produce the manifests
you expect:

```bash
helm template valkey-operator ./valkey-operator
```

Use `--set` or `-f` to exercise the paths your change affects, for example:

```bash
helm template valkey-operator ./valkey-operator \
  --set networkPolicy.enabled=true
```

### Bump the chart version

Any change to the chart's behavior or templates requires a version bump.
Increment `version` in `valkey-operator/Chart.yaml` following
[Semantic Versioning](https://semver.org/). Bump `appVersion` only when the
change targets a new release of the operator itself.

## Testing

Run these checks locally before opening a pull request.

### Lint

Static validation catches schema and templating errors:

```bash
helm lint ./valkey-operator
```

### Unit tests

The chart's unit tests live under `valkey-operator/tests/` and run with
`helm-unittest`:

```bash
helm unittest ./valkey-operator
```

Add or update tests in `valkey-operator/tests/` to cover the behavior you
change. Tests are grouped by feature (for example `networkpolicy_test.yaml`,
`poddisruptionbudget_test.yaml`); follow the existing files as a template.

### Local cluster validation

For changes that affect runtime behavior, install the chart into a local
`kind` cluster:

```bash
kind create cluster --name valkey-operator-dev

helm install valkey-operator ./valkey-operator \
  -n valkey-operator-system --create-namespace

kubectl -n valkey-operator-system get pods
```

Note that Helm does not upgrade CRDs automatically. When testing CRD changes
across versions, apply the CRDs manually first (see [UPGRADE.md](UPGRADE.md)).

Clean up when you're done:

```bash
kind delete cluster --name valkey-operator-dev
```

## Submitting Changes

### Sign your commits (DCO)

This project requires a [Developer Certificate of Origin](https://developercertificate.org/)
sign-off on every commit. Add it with the `-s` flag:

```bash
git commit -s -m "feat(operator): describe your change"
```

This appends a `Signed-off-by` line using your Git `user.name` and
`user.email`. Make sure both are configured.

### Stack large changes

For large or multi-part changes, split the work into a stack of smaller,
focused pull requests. Each PR should be independently reviewable and build on
the previous one. Smaller PRs are easier to review and faster to merge.

### Pull request checklist

Before requesting review, confirm your PR:

- [ ] Links the issue it addresses (for example, `Closes #204`)
- [ ] Includes a clear summary of what changed and why
- [ ] Bumps the chart `version` in `Chart.yaml`
- [ ] Updates `values.yaml` and `README.md` for any new or changed parameters
- [ ] Passes `helm lint ./valkey-operator`
- [ ] Passes `helm unittest ./valkey-operator`, with tests added or updated for the change
- [ ] Has all commits signed off (DCO)
- [ ] Describes how you tested the change

## Additional Information

### Chart directory structure

```
valkey-operator/
├── Chart.yaml        # Chart metadata and version
├── values.yaml       # Default configuration values
├── README.md         # Chart documentation
├── UPGRADE.md        # Version-specific upgrade notes (CRDs)
├── CHANGELOG.md      # Release history
├── crds/             # ValkeyCluster and ValkeyNode CRDs
├── templates/        # Rendered Kubernetes manifests
│   ├── _helpers.tpl
│   ├── deployment.yaml
│   ├── clusterrole.yaml
│   ├── netpolicy.yaml
│   └── ...
└── tests/            # helm-unittest test suites
    └── __snapshot__/
```

### Resources

- [Valkey Operator](https://github.com/valkey-io/valkey-operator) - upstream operator and its documentation
- [#valkey-helm Slack channel](https://valkey-oss-developer.slack.com/archives/C09JZ6N2AAV) - chat with maintainers and contributors
