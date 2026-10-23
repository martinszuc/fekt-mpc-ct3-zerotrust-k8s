#!/usr/bin/env bash
# switches the cluster to exactly one scenario: infra/scenario.sh S0|S1|S2a
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env
# forced, never inherited: the default kubeconfig on the host points at another cluster
export KUBECONFIG=$PWD/$KUBECONFIG_PATH
[[ -f $KUBECONFIG ]] || { echo "missing $KUBECONFIG, run make up" >&2; exit 1; }
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

# S2a: Cilium WireGuard; only reconfigure when the state differs (agent restart)
wireguard() {
  local now
  now=$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-wireguard}')
  if [[ $1 == on && $now != true ]]; then infra/cilium.sh manifests/s2a-wireguard/cilium-values.yaml
  elif [[ $1 == off && $now == true ]]; then infra/cilium.sh
  fi
}

# legitimate path end to end (productpage -> details, reviews -> ratings -> mongodb)
app_ready() {
  local i
  for i in $(seq 60); do
    kubectl -n "$NS" exec deploy/productpage-v1 -c productpage -- python -c \
      "import urllib.request as u; b=u.urlopen('http://localhost:9080/productpage',timeout=3).read().decode(); exit(b.count('glyphicon-star')!=9)" \
      2>/dev/null && return
    sleep 2
  done
  echo "app not healthy after scenario switch" >&2; exit 1
}

case ${1:-} in
  S0)
    kubectl delete -k manifests/s1-segmentation --ignore-not-found
    sa_automount ""
    wireguard off
    ;;
  S1)
    kubectl apply -k manifests/s1-segmentation
    sa_automount false
    wireguard off
    ;;
  S2a)
    kubectl apply -k manifests/s1-segmentation
    sa_automount false
    wireguard on
    ;;
  *) echo "usage: $0 S0|S1|S2a" >&2; exit 2 ;;
esac

# annotation, not label: namespace labels are part of Cilium identities
kubectl annotate ns "$NS" zt-scenario="$1" --overwrite
sleep "$SETTLE"
app_ready
