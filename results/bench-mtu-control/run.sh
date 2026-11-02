#!/usr/bin/env bash
# control for the node-encryption same-node anomaly: baseline + WireGuard's MTU, nothing else
set -euo pipefail
cd "$(dirname "$0")/../.."
export KUBECONFIG=$PWD/.kube/config
stamp() { echo "### $(date '+%F %T %Z') $*"; }
route_mtu() { limactl shell zt-w1 ip route show 10.42.2.0/24 | grep -o 'mtu [0-9]*'; }
stamp "switch to S0"; infra/scenario.sh S0 >/dev/null
stamp "force MTU 1405"; infra/cilium.sh results/bench-mtu-control/mtu-1405-values.yaml >/dev/null
kubectl -n bookinfo rollout restart deploy >/dev/null; kubectl -n bookinfo rollout status deploy --timeout=5m >/dev/null
stamp "route $(route_mtu)"
BENCH_OUT=results/bench-mtu-control SUITES=iperf3 IPERF_REPEATS=3 bench/run.sh; stamp "bench exit $?"
stamp "restore auto MTU"; infra/cilium.sh >/dev/null
kubectl -n bookinfo rollout restart deploy >/dev/null; kubectl -n bookinfo rollout status deploy --timeout=5m >/dev/null
stamp "route $(route_mtu)"
stamp "CONTROL DONE"
