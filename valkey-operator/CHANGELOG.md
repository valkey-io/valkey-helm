# Changelog

## Unreleased

### Added

- New value `manager.watchNamespaces`
  - Accepts a list of templatable namespaces that will be passed to `--watch-namespace` on the operator

## 0.1.1

### Fixed

- Update CRDs and RBAC to match valkey-operator v0.1.0.
  - Add persistence field and CEL validation rules to both CRDs.
  - Add serverConfigHash field to ValkeyNode CRD.
  - Add persistentvolumeclaims to ClusterRole RBAC.

## 0.1.0

Initial release.
