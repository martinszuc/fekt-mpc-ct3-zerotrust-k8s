# Measurement plan (draft 22.10.2026)

Goal: the cost of each control, attributed to exactly one change. Not implemented yet (`bench/` is empty); this is the design.

## Comparisons

| Delta | Control measured |
|---|---|
| S1 vs S0 | NetworkPolicy enforcement in eBPF (expected near zero) |
| S2a vs S1 | WireGuard between nodes |
| S2b vs S1 | Sidecar proxies and mTLS |
| S2b vs S2a | Workload-level vs node-level encryption (core comparison) |
| S3 vs S2b | L7 authorization in the proxy |

## Metrics and paths

| Metric | Tool | Paths |
|---|---|---|
| Latency p50, p95, p99, errors | fortio client at constant QPS | (a) fortio to fortio echo server, same-node; (b) same, cross-node; (c) fortio to productpage, full app (4 cross-node hops) |
| Throughput (Gbit/s, retransmits) | iperf3, TCP, 1 stream | same-node, cross-node |
| CPU and memory | `kubectl top` (metrics-server, 15 s resolution) | nodes, Cilium agents, sidecars (`istio-proxy`), app pods during the latency runs |

Paths (a) and (b) isolate per-hop network cost; (c) shows the effect on a real request.
Benchmark pods are pinned with `nodeSelector` (client on zt-w1, server on zt-w1 or zt-w2), like the app.
In S1+ they get their own allow rules; in S2b/S3 they get sidecars, so the client-side proxy is part of the cost.

## Protocol

1. Calibration (once): find the saturation rate of path (c) in the heaviest scenario (S3); use about 50 % of it as the fixed QPS for all scenarios, so no scenario is measured at saturation.
2. Per scenario and path: one 30 s warm-up run (discarded), then 5 runs of 60 s (fortio) or 30 s with the first 5 s omitted (iperf3, `-O 5`).
3. Report the median across runs and the min to max spread.
4. Interleave scenarios where possible (rounds S0, S1, S2a, S2b, S3) so slow drift on the laptop does not land on one scenario.

## Controlled conditions

- Fixed VM sizing (3 x 4 vCPU / 8 GiB), pinned versions (`docs/versions.md`), fixed pod placement.
- Podman machine stopped, laptop on power, no other heavy load; record time of each run.
- Scenario switched only via `make s0|s1|s2a|...`, which waits until the app responds end to end.
- Each run records scenario, path, QPS, connections, duration and tool versions.

## Output

| File | Columns |
|---|---|
| `results/bench/latency.csv` | time, scenario, path, run, qps_target, qps_actual, connections, p50_ms, p95_ms, p99_ms, errors |
| `results/bench/throughput.csv` | time, scenario, path, run, gbps, retransmits |
| `results/bench/resources.csv` | time, scenario, path, run, object (node/pod/container), cpu_mcores, mem_mib |

Raw fortio JSON and iperf3 JSON stay next to the CSVs; `make plot` builds the figures from the CSVs.

## Threats to validity

- VMs on one laptop (Apple M4 Pro, vz): absolute numbers are not representative, only relative differences between scenarios are.
- Cross-node traffic never leaves the host (socket_vmnet), so "network" latency is mostly CPU and virtualization cost.
- WireGuard lowers the pod MTU (cilium_wg0 1405); that is part of the S2a cost, not a separate variable.
- metrics-server samples every 15 s, so resource numbers are averages over the run, not peaks.
- fortio at constant QPS reports queueing delay when a scenario approaches saturation; calibration (step 1) is meant to prevent this.
