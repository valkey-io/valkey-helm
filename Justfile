# Valkey Helm Chart Tasks

# Run helm-unittest tests on all charts
test:
    @echo "=== Running Unit Tests ==="
    helm unittest ./valkey
    helm unittest ./valkey-cluster
    helm unittest ./valkey-operator
    helm unittest ./valkey-resources

# Lint the Helm charts
lint:
    @echo "=== Linting Helm Charts ==="
    helm lint ./valkey
    helm lint ./valkey-cluster
    helm lint ./valkey-operator
    helm lint ./valkey-resources

# Render templates with default values
template:
    helm template valkey ./valkey

template-cluster:
    helm template valkey-cluster ./valkey-cluster

template-resources:
    helm template my-cluster ./valkey-resources

# Render templates with auth enabled
template-auth:
    helm template valkey ./valkey \
        --set auth.enabled=true \
        --set auth.generateDefaultUser.enabled=true

# Package the charts
package:
    helm package ./valkey
    helm package ./valkey-cluster
    helm package ./valkey-operator
    helm package ./valkey-resources

# Run all validations
validate: lint test
    @echo "=== All validations passed ==="
