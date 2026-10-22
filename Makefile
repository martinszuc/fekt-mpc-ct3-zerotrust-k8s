SHELL := /usr/bin/env bash
export KUBECONFIG := $(CURDIR)/.kube/config

.PHONY: up down status app s0 s1 test bench plot

up:
	infra/up.sh

down:
	infra/down.sh

status:
	limactl list
	kubectl get nodes -o wide
	cilium status

app:
	kubectl apply -k manifests/app
	kubectl -n bookinfo rollout status deploy --timeout=10m

# seconds for Cilium to regenerate endpoints after a policy change
SETTLE ?= 5

# scenarios: each target leaves exactly one scenario applied and records it as a namespace annotation (labels would change Cilium identities)
s0:
	kubectl delete -k manifests/s1-segmentation --ignore-not-found
	kubectl annotate ns bookinfo zt-scenario=S0 --overwrite
	sleep $(SETTLE)

s1:
	kubectl apply -k manifests/s1-segmentation
	kubectl annotate ns bookinfo zt-scenario=S1 --overwrite
	sleep $(SETTLE)

test:
	tests/run.sh

bench:
	@echo "not implemented yet (bench/)"; exit 1

plot:
	@echo "not implemented yet (scripts/)"; exit 1
