#!/usr/bin/env bash
# resume of the overnight sweeps after the lid-close pause (29.10.2026)
set -u
cd "$(dirname "$0")/../../.."
export KUBECONFIG=$PWD/.kube/config
stamp() { echo "### $(date '+%F %T %Z') $*"; }
export QPS_ECHO=2000 QPS_APP=100
stamp "start resume"
SUITES=payload ROUNDS=1 SWEEP_REPEATS=2 bench/run.sh S2a; stamp "S2a payload exit $?"
SUITES="qps payload" ROUNDS=1 SWEEP_REPEATS=2 bench/run.sh S1 S0; stamp "S1 S0 sweeps exit $?"
infra/scenario.sh S3; stamp "restore S3 exit $?"
stamp "RESUME DONE"
