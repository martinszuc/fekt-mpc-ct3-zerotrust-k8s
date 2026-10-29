#!/usr/bin/env bash
# runs the benchmark suites: bench/run.sh [SCENARIO...]   (no argument: the current scenario)
# several scenarios with ROUNDS>1 are interleaved (S0 S1 ... S0 S1 ...) against slow drift on the laptop
# all knobs are environment variables, see the defaults below; QUICK=1 is a short smoke run
source "$(dirname "$0")/lib.sh"

SUITES=${SUITES:-"idle iperf3 latency payload qps"}   # also: link (path d, once)
ROUNDS=${ROUNDS:-1}
PAUSE=${PAUSE:-5}                  # seconds between runs
CONNS=${CONNS:-8}                  # fortio connections
PCTS="50,90,95,99,99.9"
# latency at constant QPS; set after calibration (about 50 % of the S3 knee per path, see `make plot`)
REPEATS=${REPEATS:-5}
WARMUP_S=${WARMUP_S:-30}
LAT_S=${LAT_S:-60}
QPS_ECHO=${QPS_ECHO:-1000}
QPS_APP=${QPS_APP:-50}
# QPS sweep for the saturation knee; 0 means as fast as possible
SWEEP_S=${SWEEP_S:-20}
SWEEP_REPEATS=${SWEEP_REPEATS:-3}
QPS_SWEEP=${QPS_SWEEP:-"100 250 500 1000 2000 4000 8000 0"}
QPS_SWEEP_APP=${QPS_SWEEP_APP:-"10 25 50 100 200 400 0"}
# payload sweep (request body, echoed back): crosses the 1405 B WireGuard MTU and segment boundaries
PAYLOADS=${PAYLOADS:-"64 256 1024 1400 4096 16384 65536"}
PAYLOAD_QPS=${PAYLOAD_QPS:-500}
# iperf3
IPERF_S=${IPERF_S:-30}
IPERF_OMIT=${IPERF_OMIT:-5}
IPERF_REPEATS=${IPERF_REPEATS:-$REPEATS}
# idle resource baseline, subtracted from node CPU in the cost metric
IDLE_S=${IDLE_S:-30}
# kubectl top sampling during every measured run (metrics-server, 15 s windows), cross-check only
TOP=${TOP:-1}
TOP_DELAY=${TOP_DELAY:-20}
TOP_INTERVAL=${TOP_INTERVAL:-15}

if [[ ${QUICK:-0} == 1 ]]; then
  OUT=${BENCH_OUT:-results/bench-quick}
  REPEATS=2 WARMUP_S=5 LAT_S=15 SWEEP_S=5 SWEEP_REPEATS=1 IPERF_S=8 IPERF_OMIT=2 IPERF_REPEATS=2 IDLE_S=10 PAUSE=1
  TOP_DELAY=5 TOP_INTERVAL=5
fi

# macOS ships bash 3.2: no associative arrays
url() {
  case $1 in
    same|cross) echo "http://fortio-$1:8080/echo" ;;
    app) echo http://productpage:9080/productpage ;;
  esac
}

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
RAW=$OUT/raw/$RUN_ID
TMP=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p "$RAW"

record() { python3 bench/record.py "$@" || die "record.py $1 failed"; }

retry() {
  local i
  for i in 1 2 3; do
    "$@" && return
    log "attempt $i failed: $1"
    sleep 5
  done
  die "giving up after 3 attempts: $*"
}

# CPU and memory counters of every node, read in parallel on the nodes (bench/node-snapshot.sh)
# plus the pod list that maps cgroups to containers by container ID
snapshot() {
  local f=$1 vm pid ok=1 pids=()
  for vm in $NODES; do
    limactl shell --workdir / "$vm" sh -s < bench/node-snapshot.sh > "$f.$vm" 2> "$f.$vm.err" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid" || ok=0; done
  if ((!ok)); then cat "$f".*.err >&2; return 1; fi
  for vm in $NODES; do
    [[ -s $f.$vm ]] || return 1
    echo "# zt-node lima-$vm"
    cat "$f.$vm"
  done > "$f"
  kubectl get pods -A -o json > "$f.pods"
}

top_sampler() {
  local f=$1 ns
  sleep "$TOP_DELAY"
  while :; do
    { echo "# top nodes"; kubectl top nodes --no-headers 2>/dev/null
      for ns in "$NS" kube-system istio-system; do
        echo "# top pods $ns"; kubectl top pods -n "$ns" --containers --no-headers 2>/dev/null
      done
    } >> "$f" || true
    sleep "$TOP_INTERVAL"
  done
}

stop_sampler() {
  [[ -n ${1:-} ]] || return 0
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# measured <suite> <path> <repeat> <qps> <payload> <raw-file> <cmd...>
# runs cmd between two counter snapshots and writes all CSV rows; returns 1 and records nothing if
# cmd or a snapshot fails, so a retry starts a clean window (errexit is off inside `retry`)
measured() {
  local suite=$1 path=$2 rep=$3 qps=$4 payload=$5 raw=$6 pid=""
  shift 6
  local ctx=(--run-id "$RUN_ID" --scenario "$SCEN" --suite "$suite" --path "$path" --repeat "$rep"
    --qps-target "$qps" --payload-bytes "$payload" --connections "$CONNS")
  snapshot "$TMP/before" || return 1
  rm -f "$TMP/top"
  # every window carries the same sampler load, idle included, so it cancels in the idle subtraction
  if [[ $TOP == 1 ]]; then top_sampler "$TMP/top" & pid=$!; fi
  if ! "$@" > "$TMP/out"; then
    stop_sampler "$pid"
    return 1
  fi
  stop_sampler "$pid"
  # iperf3 can report an error document with exit code 0
  if [[ $suite == iperf3 || $suite == link ]] && ! jq -e 'has("error") | not' "$TMP/out" >/dev/null; then
    return 1
  fi
  snapshot "$TMP/after" || return 1
  mv "$TMP/out" "$raw"
  case $suite in
    idle) ;;
    iperf3|link) record iperf3 --out "$OUT/throughput.csv" "${ctx[@]}" "$raw" ;;
    *) record fortio --out "$OUT/latency.csv" "${ctx[@]}" "$raw" ;;
  esac
  record resources --out "$OUT/resources.csv" "${ctx[@]}" "$TMP/before" "$TMP/after" "$TMP/after.pods"
  if [[ -s $TMP/top ]]; then record top --out "$OUT/resources.csv" "${ctx[@]}" "$TMP/top"; fi
  sleep "$PAUSE"
}

fortio_load() { kubectl -n "$NS" exec "$CLIENT" -c fortio -- fortio load -json - -loglevel Warning "$@"; }

# fortio_run <suite> <path> <repeat> <qps> <payload> <seconds>; repeat 0 is a discarded warm-up
fortio_run() {
  local suite=$1 path=$2 rep=$3 qps=$4 payload=$5 secs=$6
  local args=(-qps "$qps" -c "$CONNS" -t "${secs}s" -p "$PCTS")
  if ((payload > 0)); then args+=(-payload-size "$payload"); fi
  log "$SCEN $suite $path qps=$qps payload=$payload repeat=$rep (${secs}s)"
  if ((rep == 0)); then retry fortio_load "${args[@]}" "$(url "$path")" > /dev/null; sleep "$PAUSE"; return; fi
  retry measured "$suite" "$path" "$rep" "$qps" "$payload" \
    "$RAW/$SCEN-$suite-$path-q$qps-b$payload-r$rep.json" fortio_load "${args[@]}" "$(url "$path")"
}

# one attempt; iperf3 refuses a test while the server still tears down the previous one, so callers retry
# and each attempt gets its own output (a failed attempt prints a JSON error document)
iperf_client() {
  local container=$1; shift
  if [[ $container == link ]]; then
    kubectl -n "$NS" exec deploy/link-client -- iperf3 "$@" -J
  else
    kubectl -n "$NS" exec "$CLIENT" -c iperf3 -- iperf3 "$@" -J
  fi
}

# iperf_run <path> <repeat> <seconds>
iperf_run() {
  local path=$1 rep=$2 secs=$3 args
  args=(pod -c "iperf3-$path" -p 5201 -t "$secs" -O "$IPERF_OMIT")
  log "$SCEN iperf3 $path repeat=$rep (${secs}s)"
  if ((rep == 0)); then retry iperf_client "${args[@]}" > /dev/null; sleep "$PAUSE"; return; fi
  retry measured iperf3 "$path" "$rep" 0 0 "$RAW/$SCEN-iperf3-$path-r$rep.json" iperf_client "${args[@]}"
}

# repeat numbers continue across rounds: round 2 of REPEATS=5 gives repeats 6..10
rep_range() { seq $(( ($1 - 1) * $2 + 1 )) $(( $1 * $2 )); }

suite_idle() {
  log "$SCEN idle ${IDLE_S}s"
  retry measured idle none "$1" 0 0 "$RAW/$SCEN-idle-r$1.txt" sleep "$IDLE_S"
}

suite_iperf3() {
  local path r
  for path in same cross; do
    iperf_run "$path" 0 10
    for r in $(rep_range "$1" "$IPERF_REPEATS"); do iperf_run "$path" "$r" "$IPERF_S"; done
  done
}

suite_latency() {
  local path r q
  for path in same cross app; do
    q=$QPS_ECHO; [[ $path == app ]] && q=$QPS_APP
    fortio_run latency "$path" 0 "$q" 0 "$WARMUP_S"
    for r in $(rep_range "$1" "$REPEATS"); do fortio_run latency "$path" "$r" "$q" 0 "$LAT_S"; done
  done
}

suite_payload() {
  local path size r
  for path in same cross; do
    fortio_run payload "$path" 0 "$PAYLOAD_QPS" 64 10
    for size in $PAYLOADS; do
      for r in $(rep_range "$1" "$SWEEP_REPEATS"); do fortio_run payload "$path" "$r" "$PAYLOAD_QPS" "$size" "$SWEEP_S"; done
    done
  done
}

suite_qps() {
  local path list q r
  for path in same cross app; do
    list=$QPS_SWEEP; [[ $path == app ]] && list=$QPS_SWEEP_APP
    fortio_run qps "$path" 0 "${list%% *}" 0 10
    for q in $list; do
      for r in $(rep_range "$1" "$SWEEP_REPEATS"); do fortio_run qps "$path" "$r" "$q" 0 "$SWEEP_S"; done
    done
  done
}

# path (d): host network node to node, independent of the scenario
suite_link() {
  local ip r
  kubectl apply -k bench/k8s-link
  kubectl -n "$NS" rollout status deploy/link-server deploy/link-client --timeout=5m
  ip=$(kubectl get node "$W2" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  retry iperf_client link -c "$ip" -p 5202 -t 10 > /dev/null
  for r in $(rep_range "$1" "$IPERF_REPEATS"); do
    log "link node-to-node repeat=$r (${IPERF_S}s)"
    retry measured link node "$r" 0 0 "$RAW/link-node-r$r.json" \
      iperf_client link -c "$ip" -p 5202 -t "$IPERF_S" -O "$IPERF_OMIT"
  done
  kubectl delete -k bench/k8s-link --wait=false
}

# versions and parameters of this run, prefixed per scenario where they can differ
meta() {
  local s=$1
  {
    if [[ $s == global ]]; then
      printf 'git.commit\t%s%s\n' "$(git rev-parse HEAD)" "$(git diff --quiet HEAD || echo -dirty)"
      printf 'host.macos\t%s\n' "$(sw_vers -productVersion 2>/dev/null || uname -r)"
      printf 'host.kubectl\t%s\n' "$(kubectl version --client -o json | jq -r .clientVersion.gitVersion)"
      printf 'cluster.server\t%s\n' "$(kubectl version -o json | jq -r .serverVersion.gitVersion)"
      kubectl get nodes -o json | jq -r '.items[] | "node.\(.metadata.name)\t\(.status.nodeInfo.osImage) kernel \(.status.nodeInfo.kernelVersion) \(.status.nodeInfo.containerRuntimeVersion) cpu \(.status.capacity.cpu) mem \(.status.capacity.memory)"'
      printf 'vm.sizing\t%s vCPU %s GiB %s GiB disk\n' "$VM_CPUS" "$VM_MEMORY_GIB" "$VM_DISK_GIB"
      for v in SUITES ROUNDS REPEATS WARMUP_S LAT_S CONNS QPS_ECHO QPS_APP SWEEP_S SWEEP_REPEATS QPS_SWEEP \
               QPS_SWEEP_APP PAYLOADS PAYLOAD_QPS IPERF_S IPERF_OMIT IPERF_REPEATS IDLE_S PCTS; do
        printf 'param.%s\t%s\n' "$v" "${!v}"
      done
    else
      printf '%s.cilium\t%s\n' "$s" "$(kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}')"
      printf '%s.cilium.wireguard\t%s\n' "$s" "$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-wireguard}')"
      printf '%s.istiod\t%s\n' "$s" "$(kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo none)"
      kubectl -n "$NS" get pods -l 'app in (bench-client,fortio-server,iperf3-server)' -o json | jq -r --arg s "$s" \
        '.items[].status | (.containerStatuses // []) + (.initContainerStatuses // []) | .[] | "\($s).image.\(.name)\t\(.image) \(.imageID)"' | sort -u
      printf '%s.fortio\t%s\n' "$s" "$(kubectl -n "$NS" exec "$CLIENT" -c fortio -- fortio version)"
      printf '%s.iperf3\t%s\n' "$s" "$(kubectl -n "$NS" exec "$CLIENT" -c iperf3 -- iperf3 --version | head -1)"
    fi
  } | record versions --out "$OUT/versions.csv" --run-id "$RUN_ID"
}

podman_check
if (($# == 0)); then
  set -- "$(current_scenario)"
  [[ -n $1 ]] || die "no scenario annotation on namespace $NS; pass one or run make s0"
fi
scenarios=("$@")
# fail before round 1, not hours into the run
known=" $(known_scenarios | tr '\n' ' ')"
for s in "${scenarios[@]}"; do
  [[ $known == *" $s "* ]] || die "unknown configuration '$s'; infra/scenario.sh knows:$known"
done
for suite in $SUITES; do
  declare -F "suite_$suite" >/dev/null || die "unknown suite '$suite'"
done
log "run $RUN_ID: scenarios ${scenarios[*]}, rounds $ROUNDS, suites $SUITES -> $OUT"
meta global

for round in $(seq "$ROUNDS"); do
  for SCEN in "${scenarios[@]}"; do
    if [[ $(current_scenario) != "$SCEN" ]]; then infra/scenario.sh "$SCEN"; fi
    if [[ $SUITES != link ]]; then
      bench/deploy.sh "$SCEN"
      if ((round == 1)); then meta "$SCEN"; fi
    fi
    for suite in $SUITES; do "suite_$suite" "$round"; done
  done
done
log "done: $OUT (raw JSON in $RAW)"
