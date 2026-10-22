SHELL := /usr/bin/env bash
export KUBECONFIG := $(CURDIR)/.kube/config

.PHONY: up down status test bench plot

up:
	infra/up.sh

down:
	infra/down.sh

status:
	limactl list
	kubectl get nodes -o wide
	cilium status

test:
	@echo "not implemented yet (tests/)"; exit 1

bench:
	@echo "not implemented yet (bench/)"; exit 1

plot:
	@echo "not implemented yet (scripts/)"; exit 1
