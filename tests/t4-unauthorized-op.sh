#!/usr/bin/env bash
# T4: compromised reviews (valid identity, allowed L4 path) writes ratings: POST /ratings/0
# reviews only needs GET /ratings/*; only L7 authorization (S3) can tell the methods apart
# ratings-v2 answers POST with 501 (writes exist only in the in-memory v1), so the verdict is
# whether the request reaches the app at all, not whether data changes
source "$(dirname "$0")/lib.sh"

case $SCENARIO in S3) expect=blocked ;; *) expect=succeeded ;; esac
out=$RESULTS/T4-$SCENARIO-unauthorized-op.txt
read -r pod ctr < <(attacker_in_reviews)

req() {
  kubectl -n "$NS" exec -i "$pod" -c "$ctr" -- python - http-any "$@" < tests/probe.py 2>&1 || true
}
post=$(req POST http://ratings:9080/ratings/0 '{"Reviewer1":1,"Reviewer2":1}')
# allowed operation from the same container: the sidecar denies the method, not the caller
get=$(req GET http://ratings:9080/ratings/0)
# ratings answers itself (2xx/5xx, JSON); the sidecar answers 403 with this body
if [[ $post == "OK HTTP 403 RBAC: access denied"* ]]; then observed=blocked
elif [[ $post == "OK HTTP "* ]]; then observed=succeeded
else observed=error; fi
{ echo "## compromised reviews ($pod, ephemeral container $ctr) -> POST ratings:9080/ratings/0"
  echo "$post"
  echo
  echo "## same container, allowed operation: GET ratings:9080/ratings/0"
  echo "$get"
  echo
  echo "## authorization policies in $NS"
  kubectl -n "$NS" get authorizationpolicies.security.istio.io 2>&1
} > "$out"
record T4 reviews-posts-ratings "$expect" "$observed" "$out"
exit $FAILED
