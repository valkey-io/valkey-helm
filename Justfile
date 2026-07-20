# Valkey Helm Chart Tasks

# Run helm-unittest tests on both charts
test: test-standalone test-cluster

test-standalone:
    @echo "=== Running Unit Tests (valkey) ==="
    helm unittest ./valkey

test-cluster:
    @echo "=== Running Unit Tests (valkey-cluster) ==="
    helm unittest ./valkey-cluster

# Lint both Helm charts
lint: lint-standalone lint-cluster

lint-standalone:
    @echo "=== Linting Valkey Helm Chart ==="
    helm lint ./valkey

lint-cluster:
    @echo "=== Linting Valkey Cluster Helm Chart ==="
    helm lint ./valkey-cluster

# Render templates with default values
template:
    helm template valkey ./valkey

template-cluster:
    helm template valkey-cluster ./valkey-cluster

# Render templates with auth enabled
template-auth:
    helm template valkey ./valkey \
        --set auth.enabled=true \
        --set auth.generateDefaultUser.enabled=true

# Package both charts
package: package-standalone package-cluster

package-standalone:
    helm package ./valkey

package-cluster:
    helm package ./valkey-cluster

# Run all validations
validate: lint test
    @echo "=== All validations passed ==="

