# Changelog

## Unreleased

## 0.2.2

### Added

- New value `networkPolicy` to attach a NetworkPolicy to the operator pod.
  - Nothing is rendered unless set, preserving existing behavior.
  - Supports `ingress`, `egress`, `labels`, and `annotations`; `policyTypes` is derived from the rules provided.

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
