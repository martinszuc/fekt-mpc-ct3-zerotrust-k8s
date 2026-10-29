SHELL := /usr/bin/env bash
export KUBECONFIG := $(CURDIR)/.kube/config
# MacTeX binaries are not on PATH in non-login shells
export PATH := /Library/TeX/texbin:$(PATH)

.PHONY: up down status app s0 s1 s2a s2b s3 test bench plot figures pdf

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

s2a:
	infra/scenario.sh S2a

s2b:
	infra/scenario.sh S2b

s3:
	infra/scenario.sh S3

test:
	tests/run.sh

bench:
	@echo "not implemented yet (bench/)"; exit 1

plot:
	@echo "not implemented yet (scripts/)"; exit 1

figures:
	scripts/figures.sh

pdf:
	cd docs/report && latexmk -pdf -interaction=nonstopmode -halt-on-error sablona-prace.tex
