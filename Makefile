SHELL := /usr/bin/env bash
export KUBECONFIG := $(CURDIR)/.kube/config
.PHONY: up down reproduce vm-prep status app s0 s1 s2a s2b s2b-plain s3 test demo bench bench-link plot deltas

up:
	infra/up.sh

down:
	infra/down.sh

# from scratch: down, up, app, then every configuration with attack tests (KEEP=1 keeps the VMs)
reproduce:
	infra/reproduce.sh

# also part of make up; VM_UPGRADE=1 upgrades all packages on every node
vm-prep:
	infra/vm-prep.sh

status:
	if command -v limactl >/dev/null; then limactl list; fi
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

# measurement only: sidecars with mTLS DISABLE
s2b-plain:
	infra/scenario.sh S2b-plain

test:
	tests/run.sh

# scripted terminal recording of the attacks in every configuration, results/demo/demo.mp4 (needs vhs)
demo:
	vhs demo/demo.tape

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

# make plot [BENCH_DIR=results/bench-quick] [RUN_ID=id,id] [DROP=run_id/scenario/suite,...]
BENCH_DIR ?= results/bench
# report figures from the real run go to the report repo when it is checked out next to this one;
# otherwise, and for other result dirs, figures stay next to the CSVs
TEX_DIR ?= ../mpc-ct3-zerotrust-k8s-tex
PLOT_OUT ?= $(if $(and $(filter results/bench,$(BENCH_DIR)),$(wildcard $(TEX_DIR))),$(TEX_DIR)/figures/bench,$(BENCH_DIR)/figures)
# runs behind the report figures (results/bench/RUNLOG.md); RUN_ID= DROP= selects the latest run instead
REPORT_RUN_ID := 20261029T031157Z,20261029T073604Z,20261029T073939Z,20261029T104041Z,20261029T105456Z,20261111T015852Z
REPORT_DROP := 20261029T031157Z/S0/latency,20261029T031157Z/S1/latency,20261029T031157Z/S2a/latency,20261029T031157Z/S2b-plain/latency,20261029T031157Z/S2b/latency,20261029T031157Z/S3/latency,20261029T073939Z/S2a/payload
RUN_ID ?= $(if $(filter results/bench,$(BENCH_DIR)),$(REPORT_RUN_ID))
DROP ?= $(if $(filter results/bench,$(BENCH_DIR)),$(REPORT_DROP))
plot: $(VENV)/.ok
	$(VENV)/bin/python scripts/aggregate.py --in $(BENCH_DIR) $(if $(RUN_ID),--run-id $(RUN_ID)) $(if $(DROP),--drop $(DROP))
	$(VENV)/bin/python scripts/plot.py --in $(BENCH_DIR) --out $(PLOT_OUT) $(if $(RUN_ID),--run-id $(RUN_ID)) $(if $(DROP),--drop $(DROP))

# per-round differences for the overhead table, from the run that holds the latency suite
LATENCY_RUN ?= 20261111T015852Z
deltas:
	python3 scripts/paired.py --in $(BENCH_DIR) --run-id $(LATENCY_RUN)
