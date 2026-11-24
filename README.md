# Zero-trust access control in Kubernetes (MPC-CT3)

Controlled experiment: what each zero-trust layer in Kubernetes (segmentation, transport encryption and authentication, authorization) protects against, and what it costs in latency, throughput and resources.

## Requirements

macOS on Apple Silicon (arm64), Homebrew, ~12 vCPU and 24 GB RAM free for the VMs. This is the tested setup behind all results; for Linux, Windows and other clusters see [Other platforms](#other-platforms).

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
make vm-prep  # part of make up: no automatic apt runs, pinned kernel on every node
make app      # deploy Bookinfo into namespace bookinfo
make s0       # baseline: no policies
make s1       # segmentation: default-deny NetworkPolicies, no SA tokens mounted
make s2a      # node encryption: segmentation + Cilium WireGuard between nodes
make s2b      # mesh mTLS: segmentation + Istio sidecars, mTLS STRICT
make s3       # L7 authorization: mesh mTLS + Istio AuthorizationPolicy (allow-nothing + call graph)
make s2b-plain  # mesh without mTLS: sidecars, mTLS DISABLE (measurement only)
make test     # attack tests against the current configuration, evidence in results/
make demo     # terminal recording of the attacks in every configuration (brew install vhs), results/demo/
make bench    # benchmarks of the current configuration (or SCENARIO="S0 S1 ..."), results/bench/
make plot     # summary CSVs and figures in results/bench/figures/
make down     # delete the VMs
make reproduce  # from scratch: down, up, app, every configuration with make test
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
make bench SCENARIO="S0 S1 S2a S2b-plain S2b S3"           # defaults of the main run: 5 interleaved rounds
make bench-link                                            # path (d): node to node on the host network, once
make plot                                                  # BENCH_DIR=results/bench-quick for the smoke run
```

Suites: `idle` (CPU baseline), `iperf3`, `latency` (fixed QPS), `payload` (64 B to 64 KiB), `qps` (sweep to saturation).
Knobs (`SUITES`, `REPEATS`, `QPS_ECHO`, `QPS_APP`, ...) are environment variables, defaults at the top of `bench/run.sh`; the exact commands of the report runs are in `results/bench/logs/*.sh`.
Benchmark pods run in `bookinfo` (client and same-node servers on `zt-w1`, cross-node servers on `zt-w2`), so every control applies to them.
CPU comes from cgroup `cpu.stat` and `/proc/stat` on each node (`bench/node-snapshot.sh` via `node_exec`, `infra/node.sh`), read right before and after each run.
`make plot` on `results/bench` uses the runs behind the report figures by default (`RUN_ID= DROP=` for the latest run); `RUN_ID=a,b` selects runs (for example the main run plus `make bench-link`); `DROP=run_id/scenario/suite` leaves out a part that was cut short and rerun.
Dry run without a cluster: `scripts/pipeline-selftest.py && make plot BENCH_DIR=results/bench-fake` (synthetic data through the same record, aggregate and plot steps).

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

## Other platforms

Only the macOS setup above is tested. Everything else here is untested unless marked; the defaults in `infra/config.env` are the Mac values and every setting below is an environment override, so the Mac path does not change.

| Setup | How | Status |
|---|---|---|
| Linux host, Lima with QEMU | `VM_TYPE=qemu VM_ARCH=x86_64 VM_NETWORK=lima:user-v2 make up` (socket_vmnet is macOS only; the network must let VMs reach each other) | untested |
| Own 3-node cluster | below | untested |
| kind, attack tests only | `infra/up-kind.sh`, then `source infra/kind.env` and `make app`, `make s0` ... `make test` | CI job `attack-tests`, not yet run |
| Figures from the committed data | `make plot` and `make deltas` on any OS with Python 3 and make; without make, the commands of the CI job `plot` | Mac tested; CI on Linux and Windows not yet run |
| Windows | WSL2 (Ubuntu) as the host for the scripts, plus an own cluster or kind in WSL2 | untested |

Own cluster: Cilium must be the only CNI, without kube-proxy, as with the k3s flags in `infra/up.sh` (`--flannel-backend=none --disable-network-policy --disable-kube-proxy --disable=traefik,servicelb`). Put its kubeconfig at `.kube/config`, then `infra/cilium.sh` installs Cilium and the rest works as above with:

```bash
export NODE_EXEC=ssh NODE_SSH_USER=ubuntu       # ssh <user>@<node>; extra flags in NODE_SSH_OPTS
export CP_NODE=cp W1_NODE=w1 W2_NODE=w2         # Kubernetes node names, also the ssh hosts
export NODE_IFACE=eth0                          # node NIC that carries node-to-node traffic
```

The manifests pin pods to `lima-zt-cp`, `lima-zt-w1` and `lima-zt-w2`; `infra/apply.sh` and `infra/istio.sh` put the configured names in their place at apply time. App and benchmark placement is part of the design: W1 and W2 must be different nodes, and the control plane must accept pods (istiod runs there).

kind is not for benchmarks: the node containers share the host kernel and one Docker bridge, so there is no real node-to-node link and no separate CPU per node.

## Layout

| Path | Content |
|---|---|
| `infra/` | VM sizing, pinned versions, cluster bootstrap (Lima, kind) |
| `manifests/` | demo app and per-configuration defenses |
| `tests/` | attack scripts, one per attack |
| `bench/` | fortio and iperf3 runners |
| `results/` | raw CSV, packet captures, logs |
| `scripts/` | aggregation and plotting |
| `docs/` | threat model, measurement plan, versions |
| `.github/workflows/` | CI: attack tests on kind, figures on Linux and Windows |
