#!/usr/bin/env bash
# runs all attack tests against the current scenario; non-zero if any outcome differs from the expectation
source "$(dirname "$0")/lib.sh"
# one run id and commit for every row of this run
export SCENARIO RUN_ID GIT_SHA
tests/env-snapshot.sh
rc=0
for t in t1-lateral.sh t2-sniff.sh t3-rogue-pod.sh t4-unauthorized-op.sh t5-valid-identity.sh t6-sa-token.sh; do
  tests/"$t" || rc=1
done
echo "run $RUN_ID ($SCENARIO, $GIT_SHA): $(awk -F, -v r="$RUN_ID" '$9==r && $7=="PASS"' "$CSV" | wc -l | tr -d ' ') pass, $(awk -F, -v r="$RUN_ID" '$9==r && $7!="PASS"' "$CSV" | wc -l | tr -d ' ') fail"
exit $rc
