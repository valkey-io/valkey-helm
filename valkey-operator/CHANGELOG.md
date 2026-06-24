# Changelog

## Unreleased
### Added
-Add metrics auth RBAC (metrics-auth-role, metrics-reader-role) support to the valkey-operator chart
 

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
