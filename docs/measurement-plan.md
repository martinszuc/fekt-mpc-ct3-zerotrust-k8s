# Measurement plan (draft 22.10.2026)

Goal: the cost of each control, attributed to exactly one change. Implemented in `bench/` (runner) and `scripts/` (aggregation, figures).

## Comparisons

| Delta | Control measured |
|---|---|
| Segmentation vs. baseline | NetworkPolicy enforcement in eBPF (expected near zero) |
| Node encryption vs. segmentation | WireGuard between nodes |
| Mesh mTLS vs. segmentation | Sidecar proxies and mTLS |
| Mesh mTLS vs. node encryption | Workload-level vs node-level encryption (core comparison) |
| L7 authorization vs. mesh mTLS | L7 authorization in the proxy |

Mesh mTLS adds two things at once: sidecar proxies and mTLS. To split them, it is also measured with mTLS turned off (`PeerAuthentication` mode `DISABLE`, sidecars stay). This variant, mesh without mTLS, is measurement only, with no attack tests:

| Delta | Control measured |
|---|---|
| Mesh without mTLS vs. segmentation | Sidecar proxies (userspace L7 hop), no encryption |
| Mesh mTLS vs. mesh without mTLS | mTLS in the proxy |

## Metrics and paths

| Metric | Tool | Paths |
|---|---|---|
| Latency p50, p95, p99, errors | fortio client at constant QPS | (a) fortio to fortio echo server, same-node; (b) same, cross-node; (c) fortio to productpage, full app (4 cross-node hops) |
| Throughput (Gbit/s, retransmits) | iperf3, TCP, 1 stream | same-node, cross-node; (d) node to node on the host network, once, as the ceiling of the VM link |
| CPU and memory | cgroup `cpu.stat` / `memory.current` per container and `/proc/stat` per node, read before and after each run; `kubectl top` as cross-check | nodes, Cilium agents, sidecars (`istio-proxy`), app and benchmark pods during every run |

Paths (a) and (b) isolate per-hop network cost; (c) shows the effect on a real request.
Path (d) runs without pods or CNI. socket_vmnet switches frames in userspace, so if pod throughput in the baseline already sits near (d), the link (not the control) is the bottleneck and throughput differences must be read as CPU cost instead.

Derived metric: CPU cost per unit of work (node CPU millicores per 1000 requests for latency runs, per Gbit/s for iperf3 runs). On a laptop this is more robust than absolute latency or throughput.
Benchmark pods are pinned with `nodeSelector` (client on zt-w1, server on zt-w1 or zt-w2), like the app.
From segmentation on they get their own allow rules (`manifests/s1-segmentation/bench-allow.yaml`); with the mesh they get sidecars, so the client-side proxy is part of the cost; with L7 authorization they get their own `AuthorizationPolicy` (`bench/k8s-authz/`), so the echo servers are behind the same kind of rule as the app.

Sweeps (optional, cut first when time is short):

| Sweep | Paths | Purpose |
|---|---|---|
| QPS 100 to 8000 req/s, then unlimited (app path: 10 to 400, then unlimited) | a, b, c | saturation knee per configuration; latency vs achieved rate |
| Payload 64 B to 64 KiB (POST body, echoed back) at 500 req/s | a, b | effect of the 1405 B WireGuard MTU |

CPU counters are read on each node right before and after each run (`bench/node-snapshot.sh` over `limactl shell`), so the window is the run itself, with the node's own timestamps.
The kubelet resource endpoint is not used: it caches cgroup stats for about 10 s, which smears short runs into each other.
Node CPU in the cost metric is net of an idle baseline measured per configuration and round (30 s, no load), because WireGuard runs in kernel context that no container is charged for.
`kubectl top` runs during every measured window, idle included, so its own load is the same in all of them.

## Protocol

1. Calibration (once): run the QPS sweep (`SUITES=qps`) in the heaviest configuration (L7 authorization); `make plot` prints the knee and 50 % of the saturation rate per path. Use that as `QPS_ECHO` (paths a, b) and `QPS_APP` (path c) for all configurations, so none is measured at saturation.
2. Per configuration and path: one 30 s warm-up run (discarded), then 5 runs of 60 s (fortio) or 30 s with the first 5 s omitted (iperf3, `-O 5`). Sweeps: 3 runs of 20 s per step.
3. Report the median across runs and the min to max spread (IQR band on curves).
4. Interleave configurations: with several configurations and `ROUNDS=n`, each round runs every configuration once with `REPEATS` runs, so slow drift on the laptop does not land on one configuration.

## Controlled conditions

- Fixed VM sizing (3 x 4 vCPU / 8 GiB), pinned versions (`docs/versions.md`), fixed pod placement.
- Podman machine stopped, laptop on power, no other heavy load; record time of each run.
- Configuration switched only via its `make` target (codes in `docs/threat-model.md`), which waits until the app responds end to end.
- Each run records configuration, path, QPS, connections, duration and tool versions.

## Output

All CSVs are tidy (one value per row): time, run_id, scenario, suite, path, repeat, qps_target, payload_bytes, connections, component, object, metric, value, unit.
The `scenario` column holds the configuration code.

| File | Content |
|---|---|
| `results/bench/latency.csv` | fortio, suites latency, qps, payload: p50/p90/p95/p99/p99.9, avg, max, qps_actual, requests, errors |
| `results/bench/throughput.csv` | iperf3, suites iperf3 and link (path d): gbps, retransmits, CPU % |
| `results/bench/resources.csv` | per node and container (component node, bench, app, proxy, cilium, istiod): cpu_mcores, mem_mib; top_* from `kubectl top` |
| `results/bench/versions.csv` | per run: git commit, host, Kubernetes, node kernels, images with digests, tool versions, all parameters |
| `results/bench/raw/<run_id>/` | raw fortio and iperf3 JSON |

The CSVs are append-only; every row carries its `run_id`.
`make plot` aggregates the latest run (or `RUN_ID=a,b`) into `summary.csv` (median, IQR, min, max), `cost.csv` (CPU per 1000 req/s and per Gbit/s, per run) and `knee.csv` next to the CSVs, and draws the figures into `docs/figures/bench/`.

## Threats to validity

- VMs on one laptop (Apple M4 Pro, vz): absolute numbers are not representative, only relative differences between configurations are.
- Cross-node traffic never leaves the host (socket_vmnet), so "network" latency is mostly CPU and virtualization cost.
- WireGuard lowers the pod MTU (cilium_wg0 1405); that is part of the node encryption cost, not a separate variable.
- WireGuard encrypts only traffic between nodes; mesh mTLS also encrypts same-node traffic. The same-node path therefore measures node encryption with no encryption at all, which must be stated next to the result.
- vz offers no vCPU pinning; the host schedules VM threads across P and E cores. Interleaved rounds and 5 repeats are the defense; spread is reported, not hidden.
- The Istio compatibility settings of Cilium (`socketLB.hostNamespaceOnly`, `cni.exclusive: false`) are set in every configuration, including the baseline, so they are not part of any delta.
- CPU is an average over the run window (counter difference), not a peak; memory is the working set at the end of the run.
- fortio at constant QPS reports queueing delay when a configuration approaches saturation; calibration (step 1) is meant to prevent this.
