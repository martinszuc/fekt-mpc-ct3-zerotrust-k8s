#!/usr/bin/env bash
# (re)creates the benchmark pods so they match the configuration (sidecar or not), verifies placement and reachability
# bench/deploy.sh <scenario>
source "$(dirname "$0")/lib.sh"
SCEN=${1:?usage: bench/deploy.sh <scenario>}

SEL='app in (bench-client,fortio-server,iperf3-server)'
kubectl apply -k bench/k8s
# L7 authorization only: an ALLOW policy changes what a workload accepts, so it must not exist elsewhere
if [[ $SCEN == S3 ]]; then
  kubectl apply -k bench/k8s-authz
else
  # the CRD exists only once Istio was installed
  kubectl delete -k bench/k8s-authz --ignore-not-found 2>/dev/null || true
fi
# fresh pods: injection is decided at pod creation, and the previous configuration may have differed
kubectl -n "$NS" rollout restart deploy -l "$SEL"
for d in $(kubectl -n "$NS" get deploy -l "$SEL" -o name); do
  kubectl -n "$NS" rollout status "$d" --timeout=5m
done
until [[ -z $(kubectl -n "$NS" get pods -l "$SEL" -o jsonpath='{.items[?(@.metadata.deletionTimestamp)].metadata.name}') ]]; do
  sleep 1
done

# placement is part of the experiment design: client and same-node servers on zt-w1, cross-node servers on zt-w2
check_node() {
  local sel=$1 want=$2 got
  got=$(kubectl -n "$NS" get pods -l "$sel" -o jsonpath='{.items[*].spec.nodeName}')
  [[ $got == "$want" ]] || die "pods $sel on '$got', expected $want"
}
check_node app=bench-client "$W1"
check_node app=fortio-server,placement=same "$W1"
check_node app=iperf3-server,placement=same "$W1"
check_node app=fortio-server,placement=cross "$W2"
check_node app=iperf3-server,placement=cross "$W2"
mesh_check "$SCEN"

# every fortio target reachable through the configuration's controls (policies, sidecars, authorization)
for u in http://fortio-same:8080/echo http://fortio-cross:8080/echo http://productpage:9080/productpage; do
  for i in $(seq 30); do
    kubectl -n "$NS" exec "$CLIENT" -c fortio -- fortio curl -quiet "$u" >/dev/null 2>&1 && continue 2
    sleep 2
  done
  die "bench-client cannot reach $u"
done
log "bench pods ready ($SCEN)"
