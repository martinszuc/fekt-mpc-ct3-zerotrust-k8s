# shared helpers for attack tests; sourced, not run
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source infra/config.env
# forced, never inherited: the default kubeconfig on the host points at another cluster
export KUBECONFIG=$PWD/$KUBECONFIG_PATH
[[ -f $KUBECONFIG ]] || { echo "missing $KUBECONFIG, run make up" >&2; exit 1; }

NS=bookinfo
RESULTS=results
CSV=$RESULTS/attacks.csv
# scenario is a namespace annotation set by `make s0|s1|...`
SCENARIO=${SCENARIO:-$(kubectl get ns "$NS" -o jsonpath='{.metadata.annotations.zt-scenario}')}
SCENARIO=${SCENARIO:-S0}
mkdir -p "$RESULTS"
[[ -f $CSV ]] || echo "time,scenario,threat,check,expected,observed,verdict,evidence" > "$CSV"

# run tests/probe.py inside a workload's pod: probe <deploy> <args...>
probe() {
  local deploy=$1; shift
  kubectl -n "$NS" exec -i "deploy/$deploy" -c "${deploy%-v*}" -- python - "$@" < tests/probe.py
}

# record <threat> <check> <expected> <observed> <evidence>
record() {
  local verdict=PASS
  [[ $3 == "$4" ]] || { verdict=FAIL; FAILED=1; }
  echo "$(date -u +%FT%TZ),$SCENARIO,$1,$2,$3,$4,$verdict,$5" >> "$CSV"
  printf '%-4s %-4s %-28s expected=%-9s observed=%-9s %s\n' "$verdict" "$1" "$2" "$3" "$4" "$5"
}
FAILED=0
