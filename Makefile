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

# each target leaves exactly one scenario applied
s0:
	infra/scenario.sh S0

s1:
	infra/scenario.sh S1

test:
	tests/run.sh

bench:
	@echo "not implemented yet (bench/)"; exit 1

plot:
	@echo "not implemented yet (scripts/)"; exit 1
