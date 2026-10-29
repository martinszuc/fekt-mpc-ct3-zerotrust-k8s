# shared helpers for benchmarks; sourced, not run
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source infra/config.env
# forced, never inherited: the default kubeconfig on the host points at another cluster
export KUBECONFIG=$PWD/$KUBECONFIG_PATH
[[ -f $KUBECONFIG ]] || { echo "missing $KUBECONFIG, run make up" >&2; exit 1; }

NS=bookinfo
OUT=${BENCH_OUT:-results/bench}
CLIENT=deploy/bench-client
W1=lima-zt-w1
W2=lima-zt-w2

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

current_scenario() {
  kubectl get ns "$NS" -o jsonpath='{.metadata.annotations.zt-scenario}'
}

# configurations infra/scenario.sh accepts (its case labels)
known_scenarios() {
  sed -n 's/^  \([A-Za-z0-9-]*\))$/\1/p' infra/scenario.sh
}

# benchmarks share the laptop CPU with the podman VM otherwise
podman_check() {
  command -v podman >/dev/null || return 0
  if podman machine list --format json 2>/dev/null | jq -e 'any(.[]; .Running == true)' >/dev/null; then
    die "podman machine is running; stop it first: podman machine stop"
  fi
}

# mesh configurations must have a sidecar in the client and the expected mTLS mode, the others neither
mesh_check() {
  local scenario=$1 has mode dr
  # native sidecars live in initContainers
  has=$(kubectl -n "$NS" get pod -l app=bench-client \
    -o jsonpath='{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}')
  mode=$(kubectl -n "$NS" get peerauthentication default -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || true)
  # clients send plaintext only with this DestinationRule (auto mTLS otherwise)
  dr=$(kubectl -n "$NS" get destinationrule mesh-plaintext -o name 2>/dev/null || true)
  case $scenario in
    S2b-plain) [[ $has == *istio-proxy* && $mode == DISABLE && -n $dr ]] ;;
    S2b|S3)    [[ $has == *istio-proxy* && $mode == STRICT && -z $dr ]] ;;
    *)         [[ $has != *istio-proxy* && -z $mode && -z $dr ]] ;;
  esac || die "$scenario: bench-client containers '$has', mTLS mode '$mode', plaintext rule '$dr'"
}
