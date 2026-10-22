#!/usr/bin/env bash
# T1: compromised productpage (frontend) moves laterally to the database and to a backend it never calls
source "$(dirname "$0")/lib.sh"

case $SCENARIO in S0) expect=succeeded ;; *) expect=blocked ;; esac
out=$RESULTS/T1-$SCENARIO-lateral.txt
: > "$out"
start=$(date -u +%FT%TZ)

check() {
  local name=$1 want=$2; shift 2
  local res observed
  res=$(probe productpage-v1 "$@" 2>&1) && observed=succeeded || observed=blocked
  printf '## %s: productpage -> %s\n%s\n\n' "$name" "$*" "$res" >> "$out"
  record T1 "$name" "$want" "$observed" "$out"
}

check frontend-to-db "$expect" mongo mongodb 27017
check frontend-to-ratings "$expect" http http://ratings:9080/ratings/0
# legitimate path must keep working in every scenario
check frontend-to-details-allowed succeeded http http://details:9080/details/0

# policy verdicts from the Cilium agent on the attacker's node
node=$(kubectl -n "$NS" get pod -l app=productpage -o jsonpath='{.items[0].spec.nodeName}')
agent=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName="$node" -o name)
{ echo "## hubble: dropped flows from productpage since $start (agent on $node)"
  kubectl -n kube-system exec "$agent" -c cilium-agent -- \
    hubble observe --from-label app=productpage --type drop --since "$start" -o compact 2>&1 | tail -12
} >> "$out"
exit $FAILED
