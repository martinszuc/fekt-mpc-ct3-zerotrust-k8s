SHELL := /usr/bin/env bash
export KUBECONFIG := $(CURDIR)/.kube/config
# MacTeX binaries are not on PATH in non-login shells
export PATH := /Library/TeX/texbin:$(PATH)

.PHONY: up down status app s0 s1 s2a s2b s2b-plain test bench bench-link plot figures pdf

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

# measurement only: sidecars with mTLS DISABLE
s2b-plain:
	infra/scenario.sh S2b-plain

test:
	tests/run.sh

# make bench [SCENARIO="S0 S1 ..."] [ROUNDS=n] [QUICK=1]; other knobs in bench/run.sh
bench:
	bench/run.sh $(SCENARIO)

# path (d) node to node on the host network, once
bench-link:
	SUITES=link bench/run.sh

VENV := scripts/.venv
$(VENV)/.ok: scripts/requirements.txt
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q -r scripts/requirements.txt
	touch $@

# make plot [BENCH_DIR=results/bench-quick] [RUN_ID=id,id]
BENCH_DIR ?= results/bench
# report figures only from the real run; other result dirs keep their figures next to the CSVs
PLOT_OUT ?= $(if $(filter results/bench,$(BENCH_DIR)),docs/figures/bench,$(BENCH_DIR)/figures)
plot: $(VENV)/.ok
	$(VENV)/bin/python scripts/aggregate.py --in $(BENCH_DIR) $(if $(RUN_ID),--run-id $(RUN_ID))
	$(VENV)/bin/python scripts/plot.py --in $(BENCH_DIR) --out $(PLOT_OUT) $(if $(RUN_ID),--run-id $(RUN_ID))

figures:
	scripts/figures.sh

pdf:
	cd docs/report && latexmk -pdf -interaction=nonstopmode -halt-on-error sablona-prace.tex
