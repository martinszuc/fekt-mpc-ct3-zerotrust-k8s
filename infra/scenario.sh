#!/usr/bin/env bash
# switches the cluster to exactly one scenario: infra/scenario.sh S0|S1|S2a|S2b|S2b-plain|S3
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env
# forced, never inherited: the default kubeconfig on the host points at another cluster
export KUBECONFIG=$PWD/$KUBECONFIG_PATH
[[ -f $KUBECONFIG ]] || { echo "missing $KUBECONFIG, run make up" >&2; exit 1; }
NS=bookinfo
SETTLE=${SETTLE:-5}   # seconds for Cilium to regenerate endpoints after a policy change
RESTART=0             # tokens and sidecars are set at pod creation only

# S1 token hardening: false on every SA; "" removes the field (Kubernetes default: mount)
sa_automount() {
  local want=$1 sa
  for sa in $(kubectl -n "$NS" get sa -o name); do
    [[ $(kubectl -n "$NS" get "$sa" -o jsonpath='{.automountServiceAccountToken}') == "$want" ]] && continue
    kubectl -n "$NS" patch "$sa" -p "{\"automountServiceAccountToken\": ${want:-null}}"
    RESTART=1
  done
}

# S2a: Cilium WireGuard; only reconfigure when the state differs (agent restart)
wireguard() {
  local now
  now=$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-wireguard}')
  if [[ $1 == on && $now != true ]]; then infra/cilium.sh manifests/s2a-wireguard/cilium-values.yaml
  elif [[ $1 == off && $now == true ]]; then infra/cilium.sh
  fi
}

# number of app pods (test pods excluded) that carry an istio-proxy sidecar (classic or native)
sidecars() {
  kubectl -n "$NS" get pods -o json | jq -r '
    [.items[] | select(.metadata.name | startswith("rogue-") | not)
     | select(([.spec.containers[].name, (.spec.initContainers // [])[].name] | index("istio-proxy")) != null)]
    | length'
}

# S2b: Istio sidecars with mTLS STRICT; S2b-plain: same with mTLS DISABLE (measurement only)
# the control plane exists only in mesh scenarios; mesh on <kustomize dir> | mesh off
mesh() {
  local total with
  if [[ $1 == on ]]; then
    infra/istio.sh on
    kubectl apply -k "$2"
    # S2b-plain leaves a plaintext DestinationRule behind
    [[ $2 == manifests/s2b-plain ]] || kubectl -n "$NS" delete destinationrule mesh-plaintext --ignore-not-found
    kubectl label ns "$NS" istio-injection=enabled --overwrite
  else
    kubectl -n "$NS" delete networkpolicy allow-istiod --ignore-not-found
    kubectl -n "$NS" delete peerauthentication default --ignore-not-found 2>/dev/null || true
    kubectl -n "$NS" delete destinationrule mesh-plaintext --ignore-not-found 2>/dev/null || true
    kubectl label ns "$NS" istio-injection-
  fi
  total=$(kubectl -n "$NS" get pods -o json | jq '[.items[] | select(.metadata.name | startswith("rogue-") | not)] | length')
  with=$(sidecars)
  if [[ $1 == on && $with != "$total" ]] || [[ $1 == off && $with != 0 ]]; then RESTART=1; fi
}

# S3: Istio AuthorizationPolicy on top of S2b; policies take effect via xDS, no restart
authz() {
  if [[ $1 == on ]]; then kubectl apply -k manifests/s3-authz
  else kubectl delete -k manifests/s3-authz --ignore-not-found 2>/dev/null || true
  fi
}

restart_app() {
  ((RESTART)) || return 0
  kubectl -n "$NS" rollout restart deploy
  kubectl -n "$NS" rollout status deploy --timeout=5m
  # tests exec into deployments, so terminating pods must be gone
  until [[ -z $(kubectl -n "$NS" get pods -o jsonpath='{.items[?(@.metadata.deletionTimestamp)].metadata.name}') ]]; do sleep 1; done
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
    authz off
    mesh off
    ;;
  S1)
    kubectl apply -k manifests/s1-segmentation
    sa_automount false
    wireguard off
    authz off
    mesh off
    ;;
  S2a)
    kubectl apply -k manifests/s1-segmentation
    sa_automount false
    wireguard on
    authz off
    mesh off
    ;;
  S2b)
    kubectl apply -k manifests/s1-segmentation
    sa_automount false
    wireguard off
    mesh on manifests/s2b-mtls
    authz off
    ;;
  S2b-plain)
    kubectl apply -k manifests/s1-segmentation
    sa_automount false
    wireguard off
    mesh on manifests/s2b-plain
    authz off
    ;;
  S3)
    kubectl apply -k manifests/s1-segmentation
    sa_automount false
    wireguard off
    mesh on manifests/s2b-mtls
    authz on
    ;;
  *) echo "usage: $0 S0|S1|S2a|S2b|S2b-plain|S3" >&2; exit 2 ;;
esac

restart_app
# control plane goes only after no pod depends on it
[[ $1 == S2b || $1 == S2b-plain || $1 == S3 ]] || infra/istio.sh off

# annotation, not label: namespace labels are part of Cilium identities
kubectl annotate ns "$NS" zt-scenario="$1" --overwrite
sleep "$SETTLE"
app_ready
