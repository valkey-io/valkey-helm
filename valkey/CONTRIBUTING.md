# Contributing to the Valkey Helm Chart

Thank you for your interest in contributing! This guide explains how to set up
your environment, make changes, test them, and submit them for review. It is
aimed at first-time contributors as well as regulars.

If anything here is unclear or out of date, please open an issue or a pull
request to improve it.

---

## Table of Contents

- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Testing](#testing)
- [Submitting Changes](#submitting-changes)
- [Additional Information](#additional-information)

---

## Getting Started

### Repository overview

This repository hosts the Helm charts for deploying [Valkey](https://valkey.io)
(an open-source, high-performance key/value datastore and Redis alternative) on
Kubernetes. It contains two charts:

| Chart            | Path               | Description                                              |
| ---------------- | ------------------ | -------------------------------------------------------- |
| `valkey`         | `./valkey`         | A lightweight chart for deploying Valkey to Kubernetes.  |
| `valkey-operator`| `./valkey-operator`| A chart for deploying the Valkey operator.               |

This guide focuses on the **`valkey`** chart.

### Prerequisites and required tools

You will need the following tools installed locally:

| Tool                                                                   | Minimum version | Purpose                                  |
| ---------------------------------------------------------------------- | --------------- | ---------------------------------------- |
| [Helm](https://helm.sh/docs/intro/install/)                            | 3.5+            | Linting, templating, and packaging.      |
| [helm-unittest](https://github.com/helm-unittest/helm-unittest) plugin | 1.0.2+          | Running the chart unit tests.            |
| [Git](https://git-scm.com/)                                            | any recent      | Version control and DCO sign-off.        |
| [just](https://github.com/casey/just) (optional)                       | any recent      | Convenience task runner (`Justfile`).    |
| A Kubernetes cluster (optional)                                        | 1.20+           | End-to-end verification (kind/minikube). |

Install the `helm-unittest` plugin:

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest --version 1.0.2
```

### Cloning the repository

Fork the repository on GitHub, then clone your fork:

```bash
git clone https://github.com/<your-username>/valkey-helm.git
cd valkey-helm
git remote add upstream https://github.com/valkey-io/valkey-helm.git
```

Keeping an `upstream` remote lets you sync with the canonical repository:

```bash
git fetch upstream
git checkout main
git merge upstream/main
```

### Setting up a local development environment

No build step is required for the chart itself. To confirm your toolchain works,
run the linter and unit tests from the repository root:

```bash
helm lint ./valkey
helm unittest ./valkey
```

If you have `just` installed, you can run all validations at once:

```bash
just validate
```

To exercise the chart against a real cluster, you can use a local one such as
[kind](https://kind.sigs.k8s.io/) or
[minikube](https://minikube.sigs.k8s.io/).

---

## Development Workflow

### Creating a feature branch

Always work on a branch off the latest `main`:

```bash
git checkout main
git pull upstream main
git checkout -b my-feature
```

Use a short, descriptive branch name (e.g. `fix-pdb-selector`,
`add-tls-support`).

### Making changes to charts, templates, or documentation

Common places you will make changes within `./valkey`:

- `templates/` — Kubernetes manifest templates (StatefulSet, Services,
  ConfigMaps, etc.) and `_helpers.tpl` for shared template logic.
- `values.yaml` — default configuration values exposed to users.
- `values.schema.json` — JSON schema validating user-supplied values. **Keep it
  in sync with `values.yaml`** when you add, remove, or rename a value.
- `README.md` — user-facing chart documentation. Update it when you change
  configurable values or behavior.
- `tests/` — `helm-unittest` test suites.

### Updating chart versions when required

Any change to the **`valkey`** chart requires a bump to the `version` field in
[`valkey/Chart.yaml`](./Chart.yaml). CI enforces this via chart-testing's
`check-version-increment` setting — a PR that modifies the chart without a
version bump will fail.

Follow [Semantic Versioning](https://semver.org/):

- **Patch** (`0.10.0` → `0.10.1`) — backward-compatible bug fixes.
- **Minor** (`0.10.0` → `0.11.0`) — backward-compatible new features.
- **Major** (`0.10.0` → `1.0.0`) — breaking changes.

The `appVersion` field tracks the version of Valkey being shipped; update it only
when you intentionally change the bundled Valkey version.

> Pure documentation-only changes that do not affect the rendered chart
> generally do not require a version bump, but when in doubt, bump the patch
> version.

### Following repository coding and documentation conventions

- Keep templates consistent with the existing style: reuse helpers from
  `_helpers.tpl` rather than duplicating logic, and quote values where Helm
  requires it.
- Make new behavior **opt-in** and preserve existing defaults so upgrades stay
  non-breaking wherever possible.
- Every new or changed configurable value should be reflected in `values.yaml`,
  `values.schema.json`, and documented in `README.md`.
- Add or update unit tests in `tests/` for any template change.

---

## Testing

All of the following run from the repository root. The same checks run in CI, so
running them locally first saves a review cycle.

### Running lint checks

```bash
helm lint ./valkey
# or
just lint
```

### Validating Helm templates

Render the templates to make sure they produce valid manifests:

```bash
helm template valkey ./valkey
# or
just template
```

Render with auth enabled to verify conditional paths:

```bash
just template-auth
```

CI additionally renders the chart against multiple Kubernetes versions
(currently `1.28.15`, `1.35.3`, and `1.36.0`). You can mirror this locally:

```bash
helm template valkey ./valkey --kube-version 1.28.15
```

### Executing repository-specific tests

The chart uses [`helm-unittest`](https://github.com/helm-unittest/helm-unittest)
for unit tests (suites live in `valkey/tests/`):

```bash
helm unittest ./valkey
# or
just test
```

If you intentionally change rendered output, you may need to update snapshots:

```bash
helm unittest -u ./valkey
```

### Verifying changes locally before submission

Run the full validation suite before opening a pull request:

```bash
just validate   # runs lint + unit tests
```

Optionally, install the chart into a local cluster for an end-to-end check:

```bash
helm install valkey ./valkey --dry-run --debug   # render + validate without applying
helm install valkey ./valkey                      # actually install (e.g. on kind/minikube)
helm test valkey                                  # run the chart's connection test pod
helm uninstall valkey
```

---

## Submitting Changes

### Commit message guidelines

- Write clear, imperative commit subjects (e.g. "Add TLS support to
  StatefulSet", not "added tls").
- Keep the subject concise; use the body to explain the *why* when it is not
  obvious.
- Group related changes into logical commits.

### DCO sign-off requirements

This project uses the [Developer Certificate of Origin](https://developercertificate.org/)
(DCO). Every commit must be signed off, certifying that you wrote the code or
otherwise have the right to submit it under the project's license.

Add a sign-off automatically with the `-s` flag:

```bash
git commit -s -m "Add TLS support to StatefulSet"
```

This appends a trailer to your commit message:

```
Signed-off-by: Your Name <your.email@example.com>
```

The name and email must match your Git configuration:

```bash
git config user.name "Your Name"
git config user.email "your.email@example.com"
```

If you forget to sign off, amend the most recent commit:

```bash
git commit --amend -s
```

To sign off a series of commits, rebase with the sign-off applied to each:

```bash
git rebase --signoff main
```

### Creating a pull request

1. Push your branch to your fork:

   ```bash
   git push origin my-feature
   ```

2. Open a pull request against the `main` branch of the upstream repository.
3. In the description, explain **what** changed and **why**, and reference any
   related issues (e.g. `Fixes #123`).
4. Confirm the checklist:
   - [ ] `helm lint ./valkey` passes.
   - [ ] `helm unittest ./valkey` passes.
   - [ ] Chart `version` bumped in `Chart.yaml` (if the chart changed).
   - [ ] `values.yaml`, `values.schema.json`, and `README.md` updated as needed.
   - [ ] All commits are signed off (DCO).

CI will run linting, unit tests, and multi-version template rendering on your
pull request. Please make sure all checks are green.

### Addressing review feedback

- Respond to review comments and push follow-up commits to the same branch — the
  pull request updates automatically.
- Keep the discussion focused and prefer additional commits over force-pushes
  during active review so reviewers can see what changed.
- Remember to sign off any new commits (`git commit -s`).
- Once approved, a maintainer will merge your pull request.

---

## Additional Information

### Repository structure overview

```
.
├── Justfile               # Convenience tasks: lint, test, template, package, validate
├── README.md              # Repository overview
├── LICENSE                # BSD 3-Clause License
├── .github/
│   ├── ct.yml             # chart-testing config (version-increment enforcement)
│   └── workflows/         # CI: lint, unit tests, template rendering, release
├── valkey/                # The Valkey Helm chart
│   ├── Chart.yaml         # Chart metadata and version
│   ├── values.yaml        # Default values
│   ├── values.schema.json # Values validation schema
│   ├── templates/         # Kubernetes manifest templates
│   └── tests/             # helm-unittest test suites
└── valkey-operator/       # The Valkey operator chart
```

### Release process

Releases are automated via GitHub Actions:

- When a change to `valkey/Chart.yaml` (or `valkey-operator/Chart.yaml`) lands on
  `main` with a new `version`, the [release workflow](../.github/workflows/release.yml)
  runs.
- It uses [chart-releaser](https://github.com/helm/chart-releaser-action) to
  package the chart, create a GitHub Release, and publish the packaged chart.
- Charts are also pushed as OCI artifacts to GitHub Container Registry (GHCR).

As a contributor, your responsibility is simply to bump the chart `version`
correctly; maintainers and automation handle the rest.

### Links and community resources

- Valkey project: <https://valkey.io>
- Chart repository: <https://github.com/valkey-io/valkey-helm>
- Helm documentation: <https://helm.sh/docs/>
- helm-unittest: <https://github.com/helm-unittest/helm-unittest>
- Developer Certificate of Origin: <https://developercertificate.org/>
- Slack: [#valkey-helm](https://valkey-oss-developer.slack.com/archives/C09JZ6N2AAV)
  on the Valkey OSS developer workspace.

---

Thanks again for contributing to the Valkey Helm Chart! 🎉
