#!/usr/bin/env bash
# T5: code execution inside the real reviews pod (valid identity, allowed path) reads ratings
# not mitigated by any scenario; evidence for the limits section
# the attacker runs as an ephemeral container: same network namespace, so same Cilium identity and (S2b+) same sidecar
source "$(dirname "$0")/lib.sh"

out=$RESULTS/T5-$SCENARIO-valid-identity.txt
pod=$(kubectl -n "$NS" get pod -l app=reviews,version=v3 -o jsonpath='{.items[0].metadata.name}')
ctr=attacker-$(date +%s)
kubectl -n "$NS" debug "pod/$pod" -c "$ctr" --image=registry.istio.io/release/examples-bookinfo-productpage-v1:1.20.3 \
  -- sleep 600 >/dev/null
for _ in $(seq 180); do
  kubectl -n "$NS" get pod "$pod" -o json | jq -e --arg c "$ctr" \
    '.status.ephemeralContainerStatuses[]? | select(.name==$c) | .state.running' >/dev/null && break
  sleep 1
done

res=$(kubectl -n "$NS" exec -i "$pod" -c "$ctr" -- python - http http://ratings:9080/ratings/0 < tests/probe.py 2>&1) \
  && observed=succeeded || observed=blocked
{ echo "## compromised reviews ($pod, ephemeral container $ctr) -> ratings:9080"
  echo "$res"
  echo
  echo "## pod identity"
  kubectl -n "$NS" get pod "$pod" -o jsonpath='SA {.spec.serviceAccountName}, labels {.metadata.labels}{"\n"}'
} > "$out"
record T5 reviews-reads-ratings succeeded "$observed" "$out"
exit $FAILED
