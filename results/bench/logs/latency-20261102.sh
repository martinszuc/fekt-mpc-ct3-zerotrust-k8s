#!/usr/bin/env bash
# latency rerun with 10 us histogram buckets (02.11.2026); parameters also in results/bench/RUNLOG.md
# same rates, rounds and durations as the 29.10 main run, only RES differs
set -u
cd "$(dirname "$0")/../../.."
export KUBECONFIG=$PWD/.kube/config
stamp() { echo "### $(date '+%F %T %Z') $*"; }
export QPS_ECHO=2000 QPS_APP=100 RES=0.00001
stamp "start latency rerun"
ROUNDS=5 REPEATS=1 SUITES="idle latency" bench/run.sh S0 S1 S2a S2b-plain S2b S3; stamp "latency exit $?"
infra/scenario.sh S3; stamp "restore S3 exit $?"
stamp "LATENCY RERUN DONE"
