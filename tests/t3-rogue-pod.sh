#!/usr/bin/env bash
# T3: attacker who can create pods in the namespace calls ratings with a copied label (app=reviews)
# three variants, from weakest to strongest workload identity:
#   no-identity  outside the mesh (sidecar opted out), default SA     -> blocked by mTLS STRICT (S2b)
#   default-sa   inside the mesh, default SA: valid but wrong identity -> authenticated, blocked only by authz (S3)
#   reused-sa    inside the mesh, runs as bookinfo-reviews             -> valid identity, not blocked by any scenario
# reused-sa needs admission control or RBAC on pod creation/SA use, which is out of scope (limit, like T5)
source "$(dirname "$0")/lib.sh"

out=$RESULTS/T3-$SCENARIO-rogue-pod.txt
: > "$out"

expect() {
  case $1:$SCENARIO in
    reused-sa:*) echo succeeded ;;
    no-identity:S0|no-identity:S1|no-identity:S2a) echo succeeded ;;
    default-sa:S0|default-sa:S1|default-sa:S2a|default-sa:S2b) echo succeeded ;;
    *) echo blocked ;;
  esac
}

# rogue <variant> <inject true|false> <serviceAccountName>
rogue() {
  local variant=$1 inject=$2 sa=$3 pod=rogue-$1 res observed
  kubectl -n "$NS" delete pod "$pod" --ignore-not-found --wait >/dev/null
  kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels:
    app: reviews   # spoofed: allowed into ratings by S1
    sidecar.istio.io/inject: "$inject"
spec:
  # placed on zt-w2 so the call to ratings (zt-w1) crosses nodes
  nodeSelector: {kubernetes.io/hostname: lima-zt-w2}
  serviceAccountName: $sa
  automountServiceAccountToken: false
  containers:
    - name: attacker
      image: registry.istio.io/release/examples-bookinfo-productpage-v1:1.20.3
      command: [sleep, "3600"]
      # never Ready, so the reviews Service never routes real traffic to it
      readinessProbe:
        exec: {command: ["false"]}
        periodSeconds: 60
YAML
  kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Running pod/"$pod" --timeout=3m >/dev/null
  # injected sidecar must hold its certificate before the call (classic or native sidecar)
  for _ in $(seq 60); do
    kubectl -n "$NS" get pod "$pod" -o json | jq -e '
      [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[] | select(.name=="istio-proxy")]
      | all(.ready)' >/dev/null && break
    sleep 2
  done
  sleep 3   # Cilium identity for the new pod
  res=$(kubectl -n "$NS" exec -i "$pod" -c attacker -- python - http http://ratings:9080/ratings/0 < tests/probe.py 2>&1) \
    && observed=succeeded || observed=blocked
  { echo "## $variant: rogue pod (app=reviews, inject=$inject, SA $sa) -> ratings:9080"
    echo "$res"
    kubectl -n "$NS" get pod "$pod" -o wide --show-labels
    echo
  } >> "$out"
  kubectl -n "$NS" delete pod "$pod" --wait=false >/dev/null
  record T3 "rogue-$variant-to-ratings" "$(expect "$variant")" "$observed" "$out"
}

rogue no-identity false default
rogue default-sa true default
rogue reused-sa true bookinfo-reviews
exit $FAILED
