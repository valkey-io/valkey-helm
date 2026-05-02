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

# Create the kind cluster and shared fixtures used by the functional suite
functional-setup:
    ./functional-tests/setup.sh

# Tear down fixtures (pass --cluster to also delete the kind cluster)
functional-teardown *ARGS:
    ./functional-tests/teardown.sh {{ARGS}}

# Run one scenario against the already-set-up kind cluster, e.g.
#   just functional-scenario off off on on off
functional-scenario tls auth shard rep istio:
    ./functional-tests/run-scenario.sh {{tls}} {{auth}} {{shard}} {{rep}} {{istio}}

# Run the full 32-scenario matrix (set FILTER='tls=on istio=on' to narrow)
functional-run:
    ./functional-tests/run-all.sh

# Run the extra (non-matrix) regression scenarios on their own
functional-extras:
    ./functional-tests/run-extra-scenarios.sh

# Run the Istio ambient-mesh regressions on their own
functional-ambient:
    ./functional-tests/run-ambient-scenarios.sh

# Full functional suite: setup + matrix + teardown including cluster
functional-test:
    ./functional-tests/setup.sh
    ./functional-tests/run-all.sh
    ./functional-tests/teardown.sh --cluster
