#!/usr/bin/env bash
# rebuilds the cluster from scratch and runs the attack tests in every configuration
# KEEP=1 skips make down (reuses the existing cluster); kind: source infra/kind.env first;
# own cluster (NODE_EXEC=ssh): always reused
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env
export KUBECONFIG=$PWD/$KUBECONFIG_PATH

case $NODE_EXEC in
  lima)   [[ ${KEEP:-0} == 1 ]] || infra/down.sh; infra/up.sh ;;
  docker) [[ ${KEEP:-0} == 1 ]] || infra/down.sh; infra/up-kind.sh ;;
  *)      [[ -f $KUBECONFIG ]] || { echo "missing $KUBECONFIG" >&2; exit 1; } ;;
esac
infra/apply.sh manifests/app
kubectl -n bookinfo rollout status deploy --timeout=10m

rc=0
for s in S0 S1 S2a S2b S3; do
  infra/scenario.sh "$s"
  tests/run.sh || rc=1
done
exit $rc
