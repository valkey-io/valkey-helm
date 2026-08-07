CLUSTER_NAME ?= valkey-e2e
NAMESPACE ?= valkey-e2e
RELEASE ?= valkey-e2e
VALUES ?= ../examples/minimal.yaml
TIMEOUT ?= 5m

.PHONY: test cluster operator install verify clean

test: cluster operator install verify

cluster:
	kind get clusters | grep -qx $(CLUSTER_NAME) || kind create cluster --name $(CLUSTER_NAME)

operator:
	helm upgrade --install valkey-operator ../../valkey-operator \
		-n valkey-operator --create-namespace --wait --timeout $(TIMEOUT)

install:
	helm upgrade --install $(RELEASE) .. \
		-n $(NAMESPACE) --create-namespace -f $(VALUES) --wait --timeout $(TIMEOUT)

verify:
	kubectl wait --for=condition=Ready valkeycluster --all -n $(NAMESPACE) --timeout=$(TIMEOUT)

clean:
	kind delete cluster --name $(CLUSTER_NAME)
