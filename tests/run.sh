#!/usr/bin/env bash
# runs all attack tests against the current scenario; non-zero if any outcome differs from the expectation
cd "$(dirname "$0")"
rc=0
for t in t1-lateral.sh t2-sniff.sh t3-rogue-pod.sh t5-valid-identity.sh t6-sa-token.sh; do ./"$t" || rc=1; done
exit $rc
