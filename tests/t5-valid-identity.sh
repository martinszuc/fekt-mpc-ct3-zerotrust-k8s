#!/usr/bin/env bash
# T5: code execution inside the real reviews pod (valid identity, allowed path) reads ratings
# not mitigated by any scenario; evidence for the limits section
source "$(dirname "$0")/lib.sh"

out=$RESULTS/T5-$SCENARIO-valid-identity.txt
read -r pod ctr < <(attacker_in_reviews)

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
