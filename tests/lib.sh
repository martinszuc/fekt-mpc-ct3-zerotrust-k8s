# shared helpers for attack tests; sourced, not run
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source infra/config.env
source infra/node.sh
# forced, never inherited: the default kubeconfig on the host points at another cluster
export KUBECONFIG=$PWD/$KUBECONFIG_PATH
[[ -f $KUBECONFIG ]] || { echo "missing $KUBECONFIG, run make up" >&2; exit 1; }

NS=bookinfo
RESULTS=${RESULTS:-results}   # demo/demo.tape writes elsewhere
CSV=$RESULTS/attacks.csv
# scenario is a namespace annotation set by `make s0|s1|...`
SCENARIO=${SCENARIO:-$(kubectl get ns "$NS" -o jsonpath='{.metadata.annotations.zt-scenario}')}
SCENARIO=${SCENARIO:-S0}
# one id per `make test` run (set by run.sh); standalone scripts get their own
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$SCENARIO}
# commit of the tested code; -dirty if infra, manifests or tests differ from it; "none" outside a git checkout
if [[ -z ${GIT_SHA:-} ]]; then
  if GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null); then
    git diff --quiet HEAD -- infra manifests tests || GIT_SHA+=-dirty
  else GIT_SHA=none; fi
fi
mkdir -p "$RESULTS"
# rows before 29.10 have no run_id and git_sha (empty trailing fields)
[[ -f $CSV ]] || echo "time,scenario,threat,check,expected,observed,verdict,evidence,run_id,git_sha" > "$CSV"

# run tests/probe.py inside a workload's pod: probe <deploy> <args...>
probe() {
  local deploy=$1; shift
  kubectl -n "$NS" exec -i "deploy/$deploy" -c "${deploy%-v*}" -- python - "$@" < tests/probe.py
}

# record <threat> <check> <expected> <observed> <evidence>; observed "error" means the check proved nothing
record() {
  local verdict=PASS
  [[ $3 == "$4" ]] || { verdict=FAIL; FAILED=1; }
  echo "$(date -u +%FT%TZ),$SCENARIO,$1,$2,$3,$4,$verdict,$5,$RUN_ID,$GIT_SHA" >> "$CSV"
  printf '%-4s %-4s %-28s expected=%-9s observed=%-9s %s\n' "$verdict" "$1" "$2" "$3" "$4" "$5"
}
FAILED=0

# outcome <probe output>: succeeded | blocked | error
# blocked only on what a control produces (drop: timeout, mTLS reject: reset, authz: 403, no token: missing file);
# anything else (refused, DNS, 5xx, failed exec) proves nothing and must not pass as blocked
outcome() {
  case $(grep -m1 -E '^(OK|FAIL) ' <<< "$1") in
    "OK "*) echo succeeded ;;
    "FAIL "*TimeoutError*|"FAIL "*"timed out"*|"FAIL "*ConnectionResetError*|"FAIL "*"HTTP Error 403"*|"FAIL "*FileNotFoundError*) echo blocked ;;
    *) echo error ;;
  esac
}

# attacker as an ephemeral container in the real reviews pod: same network namespace,
# so same Cilium identity and (mesh) same sidecar and principal; prints "<pod> <container>"
attacker_in_reviews() {
  local pod ctr
  pod=$(kubectl -n "$NS" get pod -l app=reviews,version=v3 -o jsonpath='{.items[0].metadata.name}')
  # unique per script: T4 and T5 may hit the same pod within one second
  ctr=attacker-$(date +%s)-$$
  kubectl -n "$NS" debug "pod/$pod" -c "$ctr" --image=registry.istio.io/release/examples-bookinfo-productpage-v1:1.20.3 \
    -- sleep 600 >/dev/null
  for _ in $(seq 180); do
    kubectl -n "$NS" get pod "$pod" -o json | jq -e --arg c "$ctr" \
      '.status.ephemeralContainerStatuses[]? | select(.name==$c) | .state.running' >/dev/null && break
    sleep 1
  done
  echo "$pod $ctr"
}
