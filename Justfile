# Valkey Helm Chart Tasks

# Run helm-unittest tests
test:
    @echo "=== Running Unit Tests ==="
    helm unittest ./valkey
    helm unittest ./valkey-operator
    helm unittest ./valkey-resources

# Lint the Helm charts
lint:
    @echo "=== Linting Helm Charts ==="
    helm lint ./valkey
    helm lint ./valkey-operator
    helm lint ./valkey-resources

# Render templates with default values
template:
    helm template valkey ./valkey

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
    helm package ./valkey-operator
    helm package ./valkey-resources

# Run all validations
validate: lint test
    @echo "=== All validations passed ==="

