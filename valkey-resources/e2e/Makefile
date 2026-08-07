CLUSTER_NAME ?= valkey-e2e
NAMESPACE ?= valkey-e2e
RELEASE ?= valkey-e2e
VALUES ?= ../examples/minimal.yaml
TIMEOUT ?= 5m
CHARTPATH ?= ..
TOOLS ?= kind kubectl helm docker

.PHONY: test preflight lint cluster operator install verify clean

test: preflight cluster operator install verify

preflight:
	@for t in $(TOOLS); do \
		command -v $$t >/dev/null || { echo "missing required tool: $$t"; exit 1; }; \
	done
	@docker info >/dev/null 2>&1 || { echo "docker daemon is not running"; exit 1; }
	@echo "preflight ok: $(TOOLS)"

lint: 
	helm lint ..

template:
	helm template $(RELEASE) .. -f $(VALUES)

kind-up: 
	kind get clusters | grep -qx $(CLUSTER_NAME) || kind create cluster --name $(CLUSTER_NAME)

kind-down:
	kind delete cluster --name $(CLUSTER_NAME)

operator:
	helm upgrade --install valkey-operator ../../valkey-operator \
		-n valkey-operator --create-namespace --wait --timeout $(TIMEOUT)

install:
	helm upgrade --install $(RELEASE) .. \
		-n $(NAMESPACE) --create-namespace -f $(VALUES) --wait --timeout $(TIMEOUT)

verify:
	kubectl wait --for=condition=Ready valkeycluster --all -n $(NAMESPACE) --timeout=$(TIMEOUT)
