#!/usr/bin/env bash
# overnight benchmark driver (29.10.2026); parameters also in results/bench/RUNLOG.md
set -u
cd /Users/mszuc/school/mpc-ct3-zerotrust-k8s
export KUBECONFIG=$PWD/.kube/config
stamp() { echo "### $(date '+%F %T %Z') $*"; }
export QPS_ECHO=2000 QPS_APP=100
stamp "start main"
ROUNDS=5 REPEATS=1 IPERF_REPEATS=1 SUITES="idle iperf3 latency" bench/run.sh S0 S1 S2a S2b-plain S2b S3; stamp "main exit $?"
SUITES=link bench/run.sh; stamp "link exit $?"
ROUNDS=1 SWEEP_REPEATS=2 SUITES="qps payload" bench/run.sh S3 S2b S2b-plain S2a S1 S0; stamp "sweeps exit $?"
infra/scenario.sh S3; stamp "restore S3 exit $?"
stamp "OVERNIGHT DONE"
