# Zero-trust access control in Kubernetes (MPC-CT3)

Controlled experiment: what each zero-trust layer in Kubernetes (segmentation, transport encryption and authentication, authorization) protects against, and what it costs in latency, throughput and resources.

## Requirements

macOS on Apple Silicon (arm64), Homebrew, ~12 vCPU and 24 GB RAM free for the VMs.

```bash
brew install lima socket_vmnet kubectl helm cilium-cli hubble fortio iperf3 wireshark jq yq
```

One-time socket_vmnet setup (needs sudo, nothing runs at login):

```bash
sudo mkdir -p /opt/socket_vmnet/bin
sudo install -o root -g wheel -m 0755 "$(brew --prefix)/opt/socket_vmnet/bin/socket_vmnet" /opt/socket_vmnet/bin/socket_vmnet
limactl sudoers > etc_sudoers.d_lima
sudo install -o root -g wheel -m 0444 etc_sudoers.d_lima /etc/sudoers.d/lima
```

Exact versions: [docs/versions.md](docs/versions.md).

## Usage

```bash
make up       # 3 Lima VMs (vz, Ubuntu 24.04) + k3s + Cilium (baseline)
make status   # VMs, nodes, Cilium health
make app      # deploy Bookinfo into namespace bookinfo
make s0       # baseline: no policies
make s1       # segmentation: default-deny NetworkPolicies, no SA tokens mounted
make s2a      # node encryption: segmentation + Cilium WireGuard between nodes
make s2b      # mesh mTLS: segmentation + Istio sidecars, mTLS STRICT
make s3       # L7 authorization: mesh mTLS + Istio AuthorizationPolicy (allow-nothing + call graph)
make s2b-plain  # mesh without mTLS: sidecars, mTLS DISABLE (measurement only)
make test     # attack tests against the current configuration, evidence in results/
make bench    # benchmarks of the current configuration (or SCENARIO="S0 S1 ..."), results/bench/
make plot     # summary CSVs and figures in docs/figures/bench/
make figures  # docs/figures/*.svg to PDF (report) and PNG (slides), needs Chrome
make down     # delete the VMs
```

`make up` and `make app` reapply the base config; run the configuration target (`make s1`, `make s2a`, ...) again afterwards.

After `make up`, point kubectl at the cluster:

```bash
export KUBECONFIG=$PWD/.kube/config
```

## Benchmarks

```bash
podman machine stop                                        # bench refuses to run otherwise
make bench QUICK=1                                         # smoke run, ~10 min, results/bench-quick/
make bench SCENARIO="S0 S1 S2a S2b-plain S2b S3" ROUNDS=1  # full run, ~80 min per configuration
make bench-link                                            # path (d): node to node on the host network, once
make plot                                                  # BENCH_DIR=results/bench-quick for the smoke run
```

Suites: `idle` (CPU baseline), `iperf3`, `latency` (fixed QPS), `payload` (64 B to 64 KiB), `qps` (sweep to saturation).
Knobs (`SUITES`, `REPEATS`, `QPS_ECHO`, `QPS_APP`, ...) are environment variables, defaults at the top of `bench/run.sh`.
Benchmark pods run in `bookinfo` (client and same-node servers on `zt-w1`, cross-node servers on `zt-w2`), so every control applies to them.
CPU comes from cgroup `cpu.stat` and `/proc/stat` on each node (`bench/node-snapshot.sh` via `limactl shell`), read right before and after each run.
`make plot` uses the latest run by default; `RUN_ID=a,b` selects runs (for example the main run plus `make bench-link`).
Dry run without a cluster: `scripts/fake-bench.py && make plot BENCH_DIR=results/bench-fake` (synthetic data through the same record, aggregate and plot steps).

## Attack tests

| Test | Attack | Expected |
|---|---|---|
| `tests/t1-lateral.sh` | Lateral movement: productpage reads MongoDB and calls ratings directly | succeeds in the baseline, blocked from segmentation on |
| `tests/t2-sniff.sh` | Network sniffing: capture of cross-node traffic on the node link | plaintext in baseline and segmentation, blocked by node encryption and mesh mTLS |
| `tests/t3-rogue-pod.sh` | Identity spoofing: rogue pod with copied label `app=reviews` calls ratings, three variants: outside the mesh / in the mesh as SA `default` / in the mesh with the stolen SA `bookinfo-reviews`; plus an unlabeled pod as negative control | blocked by mesh mTLS / blocked by L7 authorization / never blocked (limit); control blocked from segmentation on |
| `tests/t4-unauthorized-op.sh` | Unauthorized operation: attacker inside the real reviews pod sends `POST /ratings/0` (reviews only needs `GET`) | reaches the app everywhere except L7 authorization (sidecar 403 `RBAC: access denied`) |
| `tests/t5-valid-identity.sh` | Compromised service: attacker inside the real reviews pod (ephemeral container) reads ratings | never blocked (limit) |
| `tests/t6-sa-token.sh` | Token abuse: productpage uses its ServiceAccount token against the API server | token usable in the baseline, blocked from segmentation on; reading Secrets is denied by RBAC everywhere |

Each run appends to `results/attacks.csv` (one `run_id` per `make test`, plus the tested `git_sha`, `-dirty` if `infra/`, `manifests/` or `tests/` differ from it), writes the environment to `results/env-<configuration code>.txt` and evidence as `results/<attack code>-<configuration code>-*`; the codes are mapped in [docs/threat-model.md](docs/threat-model.md#codes-used-in-the-repository).
A check whose evidence proves nothing (for example a capture without the probe traffic) is recorded as `error` and fails.
Network sniffing captures on the node NIC inside VM `zt-w1`. The host bridge `bridge100` does not see VM-to-VM frames (`results/T2-S0-host-bridge.txt`).

The app is pinned to fixed nodes so every call crosses nodes: productpage and ratings on `zt-w1`, details, reviews and mongodb on `zt-w2`.

## Layout

| Path | Content |
|---|---|
| `infra/` | VM sizing, pinned versions, cluster bootstrap |
| `manifests/` | demo app and per-configuration defenses |
| `tests/` | attack scripts, one per attack |
| `bench/` | fortio and iperf3 runners |
| `results/` | raw CSV, packet captures, logs |
| `scripts/` | aggregation and plotting |
| `docs/` | LaTeX report, bibliography, versions |
