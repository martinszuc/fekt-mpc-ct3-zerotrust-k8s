#!/usr/bin/env bash
# switches the cluster to exactly one scenario: infra/scenario.sh S0|S1
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env
export KUBECONFIG=${KUBECONFIG:-$PWD/$KUBECONFIG_PATH}
NS=bookinfo
SETTLE=${SETTLE:-5}   # seconds for Cilium to regenerate endpoints after a policy change

# S1 token hardening: false on every SA; "" removes the field (Kubernetes default: mount)
sa_automount() {
  local want=$1 changed=0 sa
  for sa in $(kubectl -n "$NS" get sa -o name); do
    [[ $(kubectl -n "$NS" get "$sa" -o jsonpath='{.automountServiceAccountToken}') == "$want" ]] && continue
    kubectl -n "$NS" patch "$sa" -p "{\"automountServiceAccountToken\": ${want:-null}}"
    changed=1
  done
  # tokens are mounted at pod creation only
  if ((changed)); then
    kubectl -n "$NS" rollout restart deploy
    kubectl -n "$NS" rollout status deploy --timeout=5m
    # tests exec into deployments, so terminating pods must be gone
    until [[ -z $(kubectl -n "$NS" get pods -o jsonpath='{.items[?(@.metadata.deletionTimestamp)].metadata.name}') ]]; do sleep 1; done
  fi
}

case ${1:-} in
  S0)
    kubectl delete -k manifests/s1-segmentation --ignore-not-found
    sa_automount ""
    ;;
  S1)
    kubectl apply -k manifests/s1-segmentation
    sa_automount false
    ;;
  *) echo "usage: $0 S0|S1" >&2; exit 2 ;;
esac

# annotation, not label: namespace labels are part of Cilium identities
kubectl annotate ns "$NS" zt-scenario="$1" --overwrite
sleep "$SETTLE"
