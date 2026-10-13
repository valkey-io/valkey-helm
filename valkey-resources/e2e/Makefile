CLUSTER_NAME ?= valkey-e2e
NAMESPACE ?= valkey-e2e
RELEASE ?= valkey-e2e
VALUES ?= ../examples/minimal.yaml
TIMEOUT ?= 5m
CHARTPATH ?= ..
TOOLS ?= kind kubectl helm docker
CRDS ?= valkeyclusters.valkey.io valkeynodes.valkey.io
SMOKE_KEY ?= e2e:smoke
SMOKE_VAL ?= hello-e2e
GC_TIMEOUT ?= 120
OPERATOR_NS ?= valkey-operator
LOG_LINES ?= 200
KUBE_CONTEXT ?= kind-$(CLUSTER_NAME)

KUBECTL := kubectl --context $(KUBE_CONTEXT)
HELM := helm --kube-context $(KUBE_CONTEXT)

# Phases depend on each other, so never run them concurrently, even under -j.
.NOTPARALLEL:

.PHONY: e2e test preflight lint template kind-up kind-down operator-install crd-check resources-install wait-ready verify-topology smoke uninstall-check diagnostics

# Single entry point: run the whole suite, dump diagnostics if any step fails.
# A kind cluster created by this run is deleted on success and kept on failure.
e2e:
	@created=0; \
	kind get clusters 2>/dev/null | grep -qx $(CLUSTER_NAME) || created=1; \
	if $(MAKE) test; then \
		if [ $$created = 1 ]; then $(MAKE) kind-down; fi; \
	else \
		$(MAKE) diagnostics; exit 1; \
	fi

test: preflight lint template kind-up operator-install crd-check resources-install \
	wait-ready verify-topology smoke uninstall-check

preflight:
	@for t in $(TOOLS); do \
		command -v $$t >/dev/null || { echo "missing required tool: $$t"; exit 1; }; \
	done
	@docker info >/dev/null 2>&1 || { echo "docker daemon is not running"; exit 1; }
	@echo "preflight ok: $(TOOLS)"

lint:
	helm lint $(CHARTPATH)

template:
	helm template $(RELEASE) $(CHARTPATH) -f $(VALUES)

kind-up:
	kind get clusters | grep -qx $(CLUSTER_NAME) || kind create cluster --name $(CLUSTER_NAME)

operator-install:
	$(HELM) upgrade --install valkey-operator ../../valkey-operator \
		-n $(OPERATOR_NS) --create-namespace --wait --timeout $(TIMEOUT)

crd-check:
	@for c in $(CRDS); do \
		$(KUBECTL) get crd $$c >/dev/null 2>&1 || { \
			echo "missing CRD: $$c (is valkey-operator installed?)"; \
			exit 1; \
		}; \
	done
	@echo "crd-check ok: $(CRDS)"

resources-install:
	$(HELM) upgrade --install $(RELEASE) $(CHARTPATH) \
		-n $(NAMESPACE) --create-namespace -f $(VALUES) --wait --timeout $(TIMEOUT)

wait-ready:
	$(KUBECTL) wait --for=jsonpath='{.status.state}'=Ready valkeycluster --all \
		-n $(NAMESPACE) --timeout=$(TIMEOUT) \
		|| { $(KUBECTL) get valkeyclusters -n $(NAMESPACE); exit 1; }

verify-topology:
	@set -eu; \
	vc=$$($(KUBECTL) get valkeycluster -n $(NAMESPACE) -o jsonpath='{.items[0].metadata.name}'); \
	q() { $(KUBECTL) get valkeycluster $$vc -n $(NAMESPACE) -o jsonpath="{$$1}"; }; \
	shards=$$(q .spec.shards); replicas=$$(q .spec.replicas); ready=$$(q .status.readyShards); \
	expected=$$(( $$shards * (1 + $$replicas) )); \
	nodes=$$($(KUBECTL) get valkeynodes -n $(NAMESPACE) -l valkey.io/cluster=$$vc --no-headers | wc -l); \
	echo "$$vc: shards=$$shards replicas=$$replicas readyShards=$$ready nodes=$$nodes expected=$$expected"; \
	[ "$$ready" = "$$shards" ] || { echo "FAIL: readyShards $$ready != shards $$shards"; exit 1; }; \
	[ "$$nodes" = "$$expected" ] || { echo "FAIL: ValkeyNode count $$nodes != expected $$expected"; exit 1; }; \
	$(KUBECTL) wait --for=condition=Ready pod -l valkey.io/cluster=$$vc \
		-n $(NAMESPACE) --timeout=$(TIMEOUT) >/dev/null \
		|| { echo "FAIL: not all pods Ready"; $(KUBECTL) get pods -n $(NAMESPACE); exit 1; }; \
	echo "verify-topology ok"

smoke:
	@set -eu; \
	vc=$$($(KUBECTL) get valkeycluster -n $(NAMESPACE) -o jsonpath='{.items[0].metadata.name}'); \
	pod=$$($(KUBECTL) get pod -n $(NAMESPACE) -l valkey.io/cluster=$$vc -o jsonpath='{.items[0].metadata.name}'); \
	cli() { $(KUBECTL) exec -n $(NAMESPACE) $$pod -c server -- sh -c "unset VALKEYCLI_AUTH; valkey-cli $$1"; }; \
	state=$$(cli "CLUSTER INFO" | tr -d '\r' | awk -F: '/^cluster_state:/{print $$2}'); \
	[ "$$state" = "ok" ] || { echo "FAIL: cluster_state=$$state"; cli "CLUSTER INFO"; exit 1; }; \
	cli "-c SET $(SMOKE_KEY) $(SMOKE_VAL)" >/dev/null; \
	got=$$(cli "-c GET $(SMOKE_KEY)" | tr -d '\r'); \
	[ "$$got" = "$(SMOKE_VAL)" ] || { echo "FAIL: GET returned '$$got', want '$(SMOKE_VAL)'"; exit 1; }; \
	cli "-c DEL $(SMOKE_KEY)" >/dev/null; \
	echo "smoke ok: cluster_state=ok, SET/GET round-trip via $$pod"

uninstall-check:
	@set -eu; \
	vc=$$($(KUBECTL) get valkeycluster -n $(NAMESPACE) -o jsonpath='{.items[0].metadata.name}'); \
	$(HELM) uninstall $(RELEASE) -n $(NAMESPACE) --wait --timeout $(TIMEOUT); \
	for i in $$(seq 1 $(GC_TIMEOUT)); do \
		n=$$($(KUBECTL) get valkeynodes -n $(NAMESPACE) -l valkey.io/cluster=$$vc --no-headers 2>/dev/null | wc -l); \
		p=$$($(KUBECTL) get pods -n $(NAMESPACE) -l valkey.io/cluster=$$vc --no-headers 2>/dev/null | wc -l); \
		if [ "$$n" = "0" ] && [ "$$p" = "0" ]; then \
			echo "uninstall-check ok: ValkeyNodes and pods garbage collected"; exit 0; \
		fi; \
		sleep 1; \
	done; \
	echo "FAIL: leftovers after $(GC_TIMEOUT)s (nodes=$$n pods=$$p)"; \
	$(KUBECTL) get valkeynodes,pods -n $(NAMESPACE) -l valkey.io/cluster=$$vc; exit 1

# Best-effort dump for triage. Never fails, so it is safe as: make test || make diagnostics
diagnostics:
	@set -u; \
	dump() { echo; echo "===== $$1 ====="; shift; "$$@" 2>&1 || true; }; \
	dump "valkeyclusters" $(KUBECTL) get valkeyclusters -n $(NAMESPACE) -o wide; \
	dump "describe valkeyclusters" $(KUBECTL) describe valkeyclusters -n $(NAMESPACE); \
	dump "valkeynodes" $(KUBECTL) get valkeynodes -n $(NAMESPACE) -o wide; \
	dump "describe valkeynodes" $(KUBECTL) describe valkeynodes -n $(NAMESPACE); \
	dump "pods" $(KUBECTL) get pods -n $(NAMESPACE) -o wide; \
	dump "describe pods" $(KUBECTL) describe pods -n $(NAMESPACE); \
	dump "events" $(KUBECTL) get events -n $(NAMESPACE) --sort-by=.lastTimestamp; \
	dump "operator logs" $(KUBECTL) logs -n $(OPERATOR_NS) \
		-l app.kubernetes.io/name=valkey-operator --tail=$(LOG_LINES); \
	for p in $$($(KUBECTL) get pods -n $(NAMESPACE) -o name 2>/dev/null); do \
		dump "logs $$p" $(KUBECTL) logs -n $(NAMESPACE) $$p -c server --tail=$(LOG_LINES); \
	done

kind-down:
	kind delete cluster --name $(CLUSTER_NAME)
