# Benchmark run log

## 29.10.2026 overnight run

Started 2026-10-29 04:11:56 CET at commit 6de91d7, driver `results/bench/logs/overnight-20261029.sh`, output `results/bench/logs/overnight-20261029.log`.

| Part | Configurations | Rounds x repeats | Suites | Parameters |
|---|---|---|---|---|
| main | S0 S1 S2a S2b-plain S2b S3, interleaved | 5 x 1 | idle, iperf3, latency | warm-up 30 s per path and round, latency 60 s, iperf3 30 s (-O 5), idle 30 s |
| link | node to node (host network) | 1 x 5 | link | iperf3 30 s |
| sweeps | S3 S2b S2b-plain S2a S1 S0 | 1 x 2 | qps, payload | 20 s per step; QPS 100 to 8000 + unlimited (app 10 to 400 + unlimited); payload 64 B to 64 KiB at 500 req/s |

Fixed QPS: 2000 req/s (same-node and cross-node echo), 100 req/s (app). Calibration from the QUICK=1 sweep of the same night (S1, S2b-plain, S2b, S3; 1 x 5 s per step, run 20261029T022631Z): lowest saturation cross-node 7939 req/s and app 344 req/s, both in mesh without mTLS; the fixed rates are at most about 30 % of those, below the planned 50 % because the baseline and node encryption were not in the calibration sweep.
Sweep repeats 2 instead of 3 (time); sweeps run last so they can be cut.

Conditions: kernel 6.8.0-147 on all nodes, identical packages, no automatic updates; no Podman machine; laptop on power, lid open, `caffeinate -is`; attack checks 14/14 in S2b and S3 at commit 6de91d7 right before.

### Outcome

| Part | Run ID | Result |
|---|---|---|
| main | 20261029T031157Z | complete, 04:11 to 08:36, 0 errors, qps_actual at target in every run |
| link | 20261029T073604Z | complete, 1.356 Gbit/s median |
| sweeps | 20261029T073939Z | paused 10:45 (driver stopped, lid closed): S3, S2b, S2b-plain complete; S2a qps complete, payload partial (dropped from figures) |
| resume S2a payload | 20261029T104041Z | complete, 11:40 to 11:55 |
| resume S1 S0 sweeps | 20261029T105456Z | complete, 11:55 to 13:03 |

Resume driver `results/bench/logs/resume-20261029.sh`, output `resume-20261029.log`, same parameters as the overnight sweeps. Before it: zt-w1 clock fixed (all nodes within 0.1 s of the host), Cilium status OK, attack checks 14/14 in L7 authorization (run 20261029T103936Z-S3).

Figures: `make plot RUN_ID=20261029T031157Z,20261029T073604Z,20261029T073939Z,20261029T104041Z,20261029T105456Z DROP=20261029T073939Z/S2a/payload`.

Notes:
- fortio histogram resolution is the default 1 ms: on the echo paths more than 99 % of samples fall into the first bucket, so p50 to p99.9 there are interpolation artifacts (for example baseline same-node p50 0.507 ms vs mean 0.144 ms). Mean latency is exact. App path buckets are 2 to 5 ms wide. Needs `-r 0.00001` and a rerun of the latency suites.
- After the lid was closed, zt-w1's clock lagged 36 min although timesyncd reported synchronized; istio-proxy on zt-w1 stayed unready (certificate not yet valid) until `systemctl restart systemd-timesyncd`. Main and link runs ended before that; the paused sweep had already stopped.
- Cross-node iperf3 is bound by the VM link (pod 1.27 to 1.34 Gbit/s vs node 1.356); node encryption is the exception at 1.17.
- Node encryption same-node iperf3 is higher than baseline (107 vs 94.5 Gbit/s, no overlap across 5 rounds); not explained yet.

## 02.11.2026 node-encryption same-node anomaly: MTU control

Question: why same-node iperf3 under node encryption beats the baseline (107 vs 94.5 Gbit/s, 29.10). Rendered `cilium-config` differs only in `enable-wireguard` and `wireguard-persistent-keepalive`; the raw iperf3 JSON shows MSS 1303 under node encryption vs 1398 elsewhere, because Cilium lowers the pod route MTU (1450 to 1355) for every pod route, same-node ones included.

Control (`results/bench-mtu-control/`, driver `run.sh`, log `run.log`): baseline with only `MTU: 1405` (route MTU 1355, MSS 1303), 3 repeats, then the plain baseline (route MTU 1450) as same-session reference.

| Configuration | MSS | same-node Gbit/s | cross-node Gbit/s |
|---|---|---|---|
| baseline, route MTU 1355 | 1303 | 105.6 to 106.8 | 1.2 |
| baseline, auto MTU (reference) | 1398 | 88.7 to 93.3 | 1.1 to 1.3 |
| node encryption, 29.10 | 1303 | 106 to 107 | 1.17 (median) |

Result: the same-node gain is caused by the smaller MTU that comes with node encryption, not by WireGuard (same-node traffic does not pass through it). The kernel mechanism (presumably GSO segment packing on veth) is not investigated. Cluster restored to auto MTU (verified 1450).

## 02.11.2026 latency rerun, 10 us histogram buckets

Driver `results/bench/logs/latency-20261102.sh` (same rates, rounds and durations as 29.10, only `RES=0.00001`), log `latency-20261102.log`. Run 20261102T184936Z, 19:49 to 23:13, exit 0, cluster restored to S3.

Outcome: **disturbed, not used in figures.** The host display went on at 21:08 and the Mac was in use during rounds 3 and 4 (21:13 to 22:35, `pmset -g log`). Those rounds are slower in every configuration (baseline app mean 15.9, 15.8, 28.1, 20.7, 15.9 ms per round; worst mesh without mTLS round 4: app mean 44.7 ms, p99 237 ms). Medians agree with 29.10 within about 10 %, but min to max ranges overlap on the app path for every pair. Histogram fix confirmed: baseline same-node p50 0.119 ms, p99 0.611 ms (29.10: 0.507 ms artifact).

Aggregation fix: the idle node CPU baseline was pooled per configuration over all selected runs, so adding this run shifted 29.10 CPU per Gbit/s by up to 1 %. `scripts/aggregate.py` now nets each run against the latest idle run started at or before it; the 29.10 selection reproduces the committed `summary.csv` and `cost.csv` exactly.

To do: full rerun with the host untouched (display off, no use), then `make plot RUN_ID=20261029T031157Z,20261029T073604Z,20261029T073939Z,20261029T104041Z,20261029T105456Z,<new> DROP=<29.10 main>/<each scenario>/latency,20261029T073939Z/S2a/payload` and fill the latency table in `docs/report/text/rezia.tex`.

## 11.11.2026 latency rerun, host untouched

Cluster restarted from stopped VMs (`make up`), clocks within 1 s, Cilium OK, `infra/scenario.sh S3`, attack checks 14/14 (run 20261111T015737Z-S3). Host macOS 26.7.3 (26.7.2 on 29.10 and 02.11); all six configurations of the latency comparison come from this run, so the update does not affect it. Podman machine stopped, AC power, `caffeinate -dis`, no display or sleep events.

Driver `results/bench/logs/latency-20261102.sh` (unchanged), log `latency-20261111.log`. Run 20261111T015852Z, 02:58 to 06:22, exit 0, cluster restored to S3.

Outcome: **used for figures and the report.** Rounds 2 to 5 agree within a few percent. Round 1 (started 5 min after VM boot) differs: app path slower in S1 to S2b (+4 to +5 ms), same-node path faster in S0 to S2a. Medians are unaffected.

Analysis: configurations are compared per round (paired), a difference counts only when it has the same sign in all five rounds; reported value is the median of the per-round differences. The order within a round is fixed (S0, S1, S2a, S2b-plain, S2b, S3), so small consistent differences may partly come from order (noted in the limits chapter).

Figures: `make plot RUN_ID=20261029T031157Z,20261029T073604Z,20261029T073939Z,20261029T104041Z,20261029T105456Z,20261111T015852Z DROP=20261029T031157Z/S0/latency,20261029T031157Z/S1/latency,20261029T031157Z/S2a/latency,20261029T031157Z/S2b-plain/latency,20261029T031157Z/S2b/latency,20261029T031157Z/S3/latency,20261029T073939Z/S2a/payload`. Non-latency rows of `summary.csv` are identical to the previous selection.

## 18.11.2026 reverse-order latency run (aborted)

Order S3, S2b, S2b-plain, S2a, S1, S0; 5 rounds planned, same parameters as 11.11. Run 20261118T143844Z, started 15:38 CET, log `latency-reverse.log`. Rounds 1 to 3 complete with the host untouched; a game was started on the host at 18:06 (during round 4), run stopped 18:08, VMs stopped.

Outcome: **not used.** Rounds 4 and 5 are invalid; rounds 1 to 3 are kept as raw data only. To be rerun clean with all 5 rounds.

## 18.11.2026 reverse-order latency run, host untouched

Cluster restarted after a host reboot (`make up`), clocks within 0.2 s, `infra/scenario.sh S3`, attack checks 14/14 (run 20261118T190228Z-S3). Order S3, S2b, S2b-plain, S2a, S1, S0; otherwise same parameters as 11.11. Run 20261118T190331Z, 20:03 to 23:26, exit 0, log `latency-reverse-clean.log`. VMs stopped after the run.

Outcome: **control for order effects, not used for figures.** Paired analysis (`python3 scripts/paired.py --run-id 20261118T190331Z`): sidecar, mTLS and WireGuard differences repeat with the same sign in all rounds. S0 to S1 app p99 drops from +7.7 % (11.11) to +1.3 % without a consistent sign, so it was an order effect. S1 to S2a app p50 +2.1 ms (+1.3 ms on 11.11). Report text updated in the overhead and limits chapters.
