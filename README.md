# Zero-trust access control in Kubernetes

What does each zero-trust layer in Kubernetes protect against, and what does it cost?

A controlled experiment on a 3-node cluster: every configuration adds **exactly one** control, every attack maps to a threat, every result is saved as evidence.

`Kubernetes (k3s)` · `Cilium` · `WireGuard` · `Istio` · `Bookinfo` · `fortio` · `iperf3`

---

## Results at a glance

🔴 attack succeeds · 🟢 attack blocked

| Attack | Baseline | Segmentation | Node encryption | Mesh mTLS | L7 authorization |
|---|:-:|:-:|:-:|:-:|:-:|
| Lateral movement | 🔴 | 🟢 | 🟢 | 🟢 | 🟢 |
| Network sniffing | 🔴 | 🔴 | 🟢 | 🟢 | 🟢 |
| Identity spoofing, outside the mesh | 🔴 | 🔴 | 🔴 | 🟢 | 🟢 |
| Identity spoofing, other ServiceAccount | 🔴 | 🔴 | 🔴 | 🔴 | 🟢 |
| Identity spoofing, stolen ServiceAccount | 🔴 | 🔴 | 🔴 | 🔴 | 🔴 |
| Unauthorized operation | 🔴 | 🔴 | 🔴 | 🔴 | 🟢 |
| Compromised service | 🔴 | 🔴 | 🔴 | 🔴 | 🔴 |
| Token abuse | 🔴 | 🟢 | 🟢 | 🟢 | 🟢 |

Two rows stay red on purpose: a pod with a valid identity and an allowed path is not something these controls can stop.

## Configurations

```
Baseline ──► Segmentation ──┬──► Node encryption
                            └──► Mesh mTLS ──► L7 authorization
```

| Configuration | Adds | Make target |
|---|---|---|
| Baseline | Cilium, no policies | `make s0` |
| Segmentation | default-deny NetworkPolicies, no SA tokens mounted | `make s1` |
| Node encryption | Cilium WireGuard between nodes | `make s2a` |
| Mesh mTLS | Istio sidecars, mTLS `STRICT` | `make s2b` |
| L7 authorization | Istio AuthorizationPolicy (allow-nothing + call graph) | `make s3` |
| Mesh without mTLS | sidecars, mTLS `DISABLE` (measurement only) | `make s2b-plain` |

## Quick start

Tested on macOS, Apple Silicon. Needs ~12 vCPU and 24 GB RAM free for the VMs.

**1. Install tools**

```bash
brew install lima socket_vmnet kubectl helm cilium-cli hubble fortio iperf3 wireshark jq yq
```

**2. One-time socket_vmnet setup** (sudo, nothing runs at login)

```bash
sudo mkdir -p /opt/socket_vmnet/bin
sudo install -o root -g wheel -m 0755 "$(brew --prefix)/opt/socket_vmnet/bin/socket_vmnet" /opt/socket_vmnet/bin/socket_vmnet
limactl sudoers > etc_sudoers.d_lima
sudo install -o root -g wheel -m 0444 etc_sudoers.d_lima /etc/sudoers.d/lima
```

**3. Run everything**

```bash
make reproduce
```

Creates the cluster, deploys the app and runs the attack tests in every configuration.

## Commands

| Command | Does |
|---|---|
| `make up` / `make down` | create / delete the 3 VMs with k3s and Cilium |
| `make status` | VMs, nodes, Cilium health |
| `make app` | deploy Bookinfo into `bookinfo` |
| `make s0` … `make s3` | switch configuration |
| `make test` | attack tests against the current configuration |
| `make bench` | benchmarks (`QUICK=1` for a 10 min smoke run) |
| `make plot` | summary CSVs and figures |
| `make demo` | terminal recording of the attacks (needs `vhs`) |

> [!NOTE]
> `make up` and `make app` reset the base config. Run the configuration target again afterwards.

> [!IMPORTANT]
> Scripts only use `.kube/config` in this repo. For your own kubectl: `export KUBECONFIG=$PWD/.kube/config`

## Where things are

| Path | Content |
|---|---|
| [`infra/`](infra/) | VM sizing, pinned versions, cluster bootstrap |
| [`manifests/`](manifests/) | demo app and the defenses of each configuration |
| [`tests/`](tests/) | one attack script per attack |
| [`bench/`](bench/) | fortio and iperf3 runners |
| [`results/`](results/) | `attacks.csv`, packet captures, benchmark data |
| [`scripts/`](scripts/) | aggregation and plotting |
| [`docs/`](docs/) | threat model, measurement plan, versions |

## More

- [Attack tests and benchmarks in detail](docs/tests-and-benchmarks.md)
- [Linux, Windows, kind and own clusters](docs/other-platforms.md)
- [Threat model](docs/threat-model.md) · [Measurement plan](docs/measurement-plan.md) · [Versions](docs/versions.md)
