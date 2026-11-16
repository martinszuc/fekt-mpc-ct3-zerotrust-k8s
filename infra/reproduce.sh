#!/usr/bin/env bash
# rebuilds the cluster from scratch and runs the attack tests in every configuration
# KEEP=1 skips make down (reuses existing VMs)
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env
export KUBECONFIG=$PWD/$KUBECONFIG_PATH

[[ ${KEEP:-0} == 1 ]] || infra/down.sh
infra/up.sh
kubectl apply -k manifests/app
kubectl -n bookinfo rollout status deploy --timeout=10m

rc=0
for s in S0 S1 S2a S2b S3; do
  infra/scenario.sh "$s"
  tests/run.sh || rc=1
done
exit $rc
