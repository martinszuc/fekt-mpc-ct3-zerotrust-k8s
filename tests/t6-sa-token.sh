#!/usr/bin/env bash
# T6: compromised productpage uses its ServiceAccount token against the API server
source "$(dirname "$0")/lib.sh"

SA=bookinfo-productpage
out=$RESULTS/T6-$SCENARIO-sa-token.txt
: > "$out"
case $SCENARIO in S0) s0=succeeded ;; *) s0=blocked ;; esac

check() {
  local name=$1 want=$2; shift 2
  local res observed since pod
  since=$(date -u +%FT%TZ)
  res=$(probe productpage-v1 "$@" 2>&1) || true
  pod=$(kubectl -n "$NS" get pod -l app=productpage -o jsonpath='{.items[0].metadata.name}')
  printf '## %s: productpage %s\n%s\n\n' "$name" "$*" "$res" >> "$out"
  # a timeout counts as blocked only with a Hubble policy drop to the API server
  # (Service port 443, endpoint 6443 after Cilium's service translation)
  observed=$(confirm_drop "$(outcome "$res")" "$res" "$pod" "$since" "443|6443" "$out")
  record T6 "$name" "$want" "$observed" "$out"
}

check token-mounted "$s0" token
check api-reachable "$s0" api-reach
check api-authenticated "$s0" api-whoami
# baseline: RBAC denies (app SAs get nothing beyond discovery); from segmentation on the token is
# missing, so the request is never sent and RBAC is not exercised (FileNotFoundError)
check api-read-secrets blocked api-secrets "$NS"

{ echo "## RBAC: effective permissions of $SA (admin view)"
  kubectl auth can-i --list -n "$NS" --as="system:serviceaccount:$NS:$SA" 2>&1 | grep -v '^ *\[/' 
  echo "(non-resource URLs omitted: discovery, /version, health, openid)"
  echo
  echo "## RBAC: bindings that name a $NS ServiceAccount"
  kubectl get rolebindings,clusterrolebindings -A -o json | jq -r --arg ns "$NS" \
    '.items[] | select(any(.subjects[]?; .kind=="ServiceAccount" and .namespace==$ns)) | "\(.kind) \(.metadata.namespace // "-")/\(.metadata.name) -> \(.roleRef.name)"' \
    | sed 's/^$//' | grep . || echo "none"
  echo
  echo "## automountServiceAccountToken per SA"
  kubectl -n "$NS" get sa -o custom-columns=SA:.metadata.name,AUTOMOUNT:.automountServiceAccountToken
} >> "$out"
exit $FAILED
