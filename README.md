# Zero-trust access control in Kubernetes (MPC-CT3)

Controlled experiment: what each zero-trust layer in Kubernetes (segmentation, transport encryption and authentication, authorization) protects against, and what it costs in latency, throughput and resources.

## Requirements

macOS on Apple Silicon (arm64), Homebrew, ~12 vCPU and 24 GB RAM free for the VMs.

```bash
brew install lima kubectl helm cilium-cli hubble fortio iperf3 wireshark jq yq
```

Exact versions: [docs/versions.md](docs/versions.md).

## Usage

```bash
make up       # 3 Lima VMs (vz, Ubuntu 24.04) + k3s + Cilium (scenario S0 baseline)
make status   # VMs, nodes, Cilium health
make down     # delete the VMs
```

After `make up`, point kubectl at the cluster:

```bash
export KUBECONFIG=$PWD/.kube/config
```

## Layout

| Path | Content |
|---|---|
| `infra/` | VM sizing, pinned versions, cluster bootstrap |
| `manifests/` | demo app and per-scenario controls (S1 to S3) |
| `tests/` | attack scripts mapped to threats T1 to T5 |
| `bench/` | fortio and iperf3 runners |
| `results/` | raw CSV, packet captures, logs |
| `scripts/` | aggregation and plotting |
| `docs/` | LaTeX report, bibliography, versions |
