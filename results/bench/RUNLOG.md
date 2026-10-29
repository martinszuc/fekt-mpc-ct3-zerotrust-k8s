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
| sweeps | 20261029T073939Z | stopped at 10:46 (lid closed): S3, S2b, S2b-plain complete; S2a qps complete, payload partial; S1, S0 not run |

Figures: `make plot RUN_ID=20261029T031157Z,20261029T073604Z,20261029T073939Z`.

Notes:
- fortio histogram resolution is the default 1 ms: on the echo paths more than 99 % of samples fall into the first bucket, so p50 to p99.9 there are interpolation artifacts (for example baseline same-node p50 0.507 ms vs mean 0.144 ms). Mean latency is exact. App path buckets are 2 to 5 ms wide. Needs `-r 0.00001` and a rerun of the latency suites.
- After the lid was closed, zt-w1's clock lagged 36 min although timesyncd reported synchronized; istio-proxy on zt-w1 stayed unready (certificate not yet valid) until `systemctl restart systemd-timesyncd`. Main and link runs ended before that.
- Cross-node iperf3 is bound by the VM link (pod 1.27 to 1.34 Gbit/s vs node 1.356); node encryption is the exception at 1.17.
- Node encryption same-node iperf3 is higher than baseline (107 vs 94.5 Gbit/s, no overlap across 5 rounds); not explained yet.
