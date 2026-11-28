# Attack tests and benchmarks

## Attack tests

| Script | Attack | Expected |
|---|---|---|
| `tests/t1-lateral.sh` | productpage reads MongoDB and calls ratings directly | blocked from segmentation on |
| `tests/t2-sniff.sh` | capture of cross-node traffic on the node link | blocked by node encryption and mesh mTLS |
| `tests/t3-rogue-pod.sh` | rogue pod with copied label `app=reviews` calls ratings | outside the mesh: blocked by mesh mTLS · other SA: blocked by L7 authorization · stolen SA `bookinfo-reviews`: never blocked |
| `tests/t4-unauthorized-op.sh` | real reviews pod sends `POST /ratings/0` (needs only `GET`) | blocked by L7 authorization |
| `tests/t5-valid-identity.sh` | real reviews pod (ephemeral container) reads ratings | never blocked |
| `tests/t6-sa-token.sh` | productpage uses its SA token against the API server | blocked from segmentation on; reading Secrets fails everywhere |

`t3` also runs an unlabeled pod as negative control (blocked from segmentation on).

### Verdicts

- **Blocked by segmentation**: a timeout counts only if Hubble logged a `Policy denied` drop from the attacking pod to the probed port (`confirm_drop` in `tests/lib.sh`).
- **Blocked by L7 authorization**: a 403 counts only with the sidecar body `RBAC: access denied`; the unauthorized-operation check also requires `GET` to keep working.
- **Node encryption**: no frame outside WireGuard may carry a pod address (`POD_CIDR`). Capture runs on the node NIC inside `zt-w1`; the host bridge does not see VM-to-VM frames (`results/T2-S0-host-bridge.txt`).
- **`error`**: evidence that proves nothing (e.g. a capture without probe traffic) fails the check.

### Output

| File | Content |
|---|---|
| `results/attacks.csv` | one row per check, with `run_id` and `git_sha` (`-dirty` if `infra/`, `manifests/` or `tests/` changed) |
| `results/env-<config>.txt` | live versions of the run |
| `results/<attack>-<config>-*` | evidence (output, pcap, Hubble drops) |

Codes are mapped in [threat-model.md](threat-model.md#codes-used-in-the-repository). The committed CSV is curated: runs behind the report and earlier final runs only (rows before 29.10 have no `run_id` / `git_sha`).

App placement makes every call cross nodes: productpage and ratings on `zt-w1`; details, reviews and mongodb on `zt-w2`.

## Benchmarks

```bash
podman machine stop                                  # bench refuses to run otherwise
make bench QUICK=1                                   # smoke run, ~10 min, results/bench-quick/
make bench SCENARIO="S0 S1 S2a S2b-plain S2b S3"     # main run: 5 interleaved rounds
make bench-link                                      # node to node on the host network, once
make plot                                            # BENCH_DIR=results/bench-quick for the smoke run
```

| Suite | Measures |
|---|---|
| `idle` | CPU baseline |
| `iperf3` | throughput |
| `latency` | fortio at fixed QPS |
| `payload` | 64 B to 64 KiB |
| `qps` | sweep to saturation |

- **Knobs** (`SUITES`, `REPEATS`, `QPS_ECHO`, `QPS_APP`, ...): env vars, defaults at the top of `bench/run.sh`. Exact commands of the report runs: `results/bench/logs/*.sh`.
- **Placement**: pods run in `bookinfo` so every control applies; client and same-node servers on `zt-w1`, cross-node servers on `zt-w2`.
- **CPU**: cgroup `cpu.stat` and `/proc/stat` on each node, read before and after each run (`bench/node-snapshot.sh`).
- **Run selection**: `make plot` uses the report runs by default. `RUN_ID= DROP=` for the latest run, `RUN_ID=a,b` to combine runs, `DROP=run_id/scenario/suite` to leave out a part that was rerun.
- **Dry run without a cluster**: `scripts/pipeline-selftest.py && make plot BENCH_DIR=results/bench-fake`
