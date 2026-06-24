# Changelog

## Unreleased

## 0.2.5

### Changed

- terminationGracePeriodSeconds is omitted from configuration by default and uses kubernetes default (30s) unless overridden.

### Fixed

- Added configurability for terminationGracePeriodSeconds.
- Added configurability for serving metrics securely.

## 0.2.4

### Added

- Support templated values in `manager.watchNamespaces` for NetworkPolicy egress rules.

## 0.2.3

### Fixed

- Add namespace field in PodDisruptionBudget

## 0.2.2

### Added

- New value `networkPolicy` to attach a NetworkPolicy to the operator pod.
  - Nothing is rendered unless set, preserving existing behavior.
  - Once opted in, the operator's required egress (DNS, Kubernetes API server, and managed Valkey pods on the Valkey port) is injected automatically so reconciliation keeps working under egress lockdown. The Valkey rule targets `manager.watchNamespaces` (all namespaces when empty).
  - Tunable via `networkPolicy.defaultEgressRules` (default `true`), `valkeyPort` (`6379`), `apiServerPort` (`6443`), and `dnsNamespace` (`kube-system`).
  - Supports `ingress`, `egress` (merged with the defaults), `labels`, and `annotations`; `policyTypes` is derived from the rules in effect.

## 0.2.1

### Added

- Add optional PodDisruptionBudget support for the valkey-operator Deployment.

## 0.2.0

### Added

- Add `topologySpreadConstraints`, `imagePullSecrets`, and `podDisruptionBudget` fields to ValkeyCluster CRD.
- Add `config`, `imagePullSecrets`, and `topologySpreadConstraints` fields to ValkeyNode CRD.
- Add `poddisruptionbudgets` permissions to ClusterRole RBAC.
- New value `manager.watchNamespaces`
  - Accepts a list of templatable namespaces that will be passed to `--watch-namespace` on the operator

> **Note:** CRDs are not upgraded automatically by Helm. See [UPGRADE.md](UPGRADE.md) for manual steps required before upgrading to this version.

### Changed

- Valkey Operator version defaults to v0.2.0

## 0.1.1

### Fixed

- Update CRDs and RBAC to match valkey-operator v0.1.0.
  - Add persistence field and CEL validation rules to both CRDs.
  - Add serverConfigHash field to ValkeyNode CRD.
  - Add persistentvolumeclaims to ClusterRole RBAC.

## 0.1.0

Initial release.
