# Measurement plan (draft 22.10.2026)

Goal: the cost of each control, attributed to exactly one change. Not implemented yet (`bench/` is empty); this is the design.

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
| CPU and memory | `kubectl top` (metrics-server, 15 s resolution) | nodes, Cilium agents, sidecars (`istio-proxy`), app pods during the latency runs |

Paths (a) and (b) isolate per-hop network cost; (c) shows the effect on a real request.
Path (d) runs without pods or CNI. socket_vmnet switches frames in userspace, so if pod throughput in the baseline already sits near (d), the link (not the control) is the bottleneck and throughput differences must be read as CPU cost instead.

Derived metric: CPU cost per unit of work (node CPU millicores per 1000 requests for latency runs, per Gbit/s for iperf3 runs). On a laptop this is more robust than absolute latency or throughput.
Benchmark pods are pinned with `nodeSelector` (client on zt-w1, server on zt-w1 or zt-w2), like the app.
From segmentation on they get their own allow rules; with the mesh they get sidecars, so the client-side proxy is part of the cost.

## Protocol

1. Calibration (once): find the saturation rate of path (c) in the heaviest configuration (L7 authorization); use about 50 % of it as the fixed QPS for all configurations, so none is measured at saturation.
2. Per configuration and path: one 30 s warm-up run (discarded), then 5 runs of 60 s (fortio) or 30 s with the first 5 s omitted (iperf3, `-O 5`).
3. Report the median across runs and the min to max spread.
4. Interleave configurations where possible (one round through all of them, repeated) so slow drift on the laptop does not land on one configuration.

## Controlled conditions

- Fixed VM sizing (3 x 4 vCPU / 8 GiB), pinned versions (`docs/versions.md`), fixed pod placement.
- Podman machine stopped, laptop on power, no other heavy load; record time of each run.
- Configuration switched only via its `make` target (codes in `docs/threat-model.md`), which waits until the app responds end to end.
- Each run records configuration, path, QPS, connections, duration and tool versions.

## Output

| File | Columns |
|---|---|
| `results/bench/latency.csv` | time, scenario, path, run, qps_target, qps_actual, connections, p50_ms, p95_ms, p99_ms, errors |
| `results/bench/throughput.csv` | time, scenario, path, run, gbps, retransmits |
| `results/bench/resources.csv` | time, scenario, path, run, object (node/pod/container), cpu_mcores, mem_mib |

The `scenario` column holds the configuration code. Raw fortio JSON and iperf3 JSON stay next to the CSVs; `make plot` builds the figures from the CSVs.

## Threats to validity

- VMs on one laptop (Apple M4 Pro, vz): absolute numbers are not representative, only relative differences between configurations are.
- Cross-node traffic never leaves the host (socket_vmnet), so "network" latency is mostly CPU and virtualization cost.
- WireGuard lowers the pod MTU (cilium_wg0 1405); that is part of the node encryption cost, not a separate variable.
- WireGuard encrypts only traffic between nodes; mesh mTLS also encrypts same-node traffic. The same-node path therefore measures node encryption with no encryption at all, which must be stated next to the result.
- vz offers no vCPU pinning; the host schedules VM threads across P and E cores. Interleaved rounds and 5 repeats are the defense; spread is reported, not hidden.
- The Istio compatibility settings of Cilium (`socketLB.hostNamespaceOnly`, `cni.exclusive: false`) are set in every configuration, including the baseline, so they are not part of any delta.
- metrics-server samples every 15 s, so resource numbers are averages over the run, not peaks.
- fortio at constant QPS reports queueing delay when a configuration approaches saturation; calibration (step 1) is meant to prevent this.
