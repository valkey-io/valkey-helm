# Valkey Helm Chart Tasks

# Run helm-unittest tests
test:
    @echo "=== Running Unit Tests ==="
    helm unittest ./valkey

# Lint the Helm chart
lint:
    @echo "=== Linting Valkey Helm Chart ==="
    helm lint ./valkey

# Render templates with default values
template:
    helm template valkey ./valkey

# Render templates with auth enabled
template-auth:
    helm template valkey ./valkey \
        --set auth.enabled=true \
        --set auth.generateDefaultUser.enabled=true

# Package the chart
package:
    helm package ./valkey

# Run all validations
validate: lint test
    @echo "=== All validations passed ==="

