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
make test     # attack tests against the current configuration, evidence in results/
make figures  # docs/figures/*.svg to PDF (report) and PNG (slides), needs Chrome
make down     # delete the VMs
```

`make up` and `make app` reapply the base config; run the configuration target (`make s1`, `make s2a`, ...) again afterwards.

After `make up`, point kubectl at the cluster:

```bash
export KUBECONFIG=$PWD/.kube/config
```

## Attack tests

| Test | Attack | Expected |
|---|---|---|
| `tests/t1-lateral.sh` | Lateral movement: productpage reads MongoDB and calls ratings directly | succeeds in the baseline, blocked from segmentation on |
| `tests/t2-sniff.sh` | Network sniffing: capture of cross-node traffic on the node link | plaintext in baseline and segmentation, blocked by node encryption and mesh mTLS |
| `tests/t3-rogue-pod.sh` | Identity spoofing: rogue pod with copied label `app=reviews` calls ratings, three variants: outside the mesh / in the mesh as SA `default` / in the mesh with the stolen SA `bookinfo-reviews` | blocked by mesh mTLS / blocked by L7 authorization / never blocked (limit) |
| `tests/t5-valid-identity.sh` | Compromised service: attacker inside the real reviews pod (ephemeral container) reads ratings | never blocked (limit) |
| `tests/t6-sa-token.sh` | Token abuse: productpage uses its ServiceAccount token against the API server | token usable in the baseline, blocked from segmentation on; reading Secrets is denied by RBAC everywhere |

Each run appends to `results/attacks.csv` and writes evidence as `results/<attack code>-<configuration code>-*`; the codes are mapped in [docs/threat-model.md](docs/threat-model.md#codes-used-in-the-repository).
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
