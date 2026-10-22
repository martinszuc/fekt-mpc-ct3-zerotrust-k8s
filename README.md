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
make up       # 3 Lima VMs (vz, Ubuntu 24.04) + k3s + Cilium (scenario S0 baseline)
make status   # VMs, nodes, Cilium health
make app      # deploy Bookinfo into namespace bookinfo
make s0       # switch scenario: S0 baseline (no policies)
make s1       # switch scenario: S1 default-deny NetworkPolicies, no SA tokens mounted
make s2a      # switch scenario: S2a = S1 + Cilium WireGuard between nodes
make s2b      # switch scenario: S2b = S1 + Istio sidecars, mTLS STRICT
make test     # attack tests against the current scenario, evidence in results/
make figures  # docs/figures/*.svg to PDF (report) and PNG (slides), needs Chrome
make down     # delete the VMs
```

`make up` and `make app` reapply the base config; run the scenario target (`make s1`, `make s2a`, ...) again afterwards.

After `make up`, point kubectl at the cluster:

```bash
export KUBECONFIG=$PWD/.kube/config
```

## Attack tests

| Test | Threat | Expected |
|---|---|---|
| `tests/t1-lateral.sh` | T1: productpage reads MongoDB and calls ratings directly | succeeds in S0, blocked from S1 |
| `tests/t2-sniff.sh` | T2: capture of cross-node traffic on the node link | plaintext in S0/S1, blocked from S2a/S2b |
| `tests/t3-rogue-pod.sh` | T3: rogue pod with spoofed label `app=reviews` calls ratings, three variants: outside the mesh / in the mesh as SA `default` / in the mesh as SA `bookinfo-reviews` | blocked from S2b / blocked from S3 / never blocked (limit) |
| `tests/t5-valid-identity.sh` | T5: attacker inside the real reviews pod (ephemeral container) reads ratings | never blocked (limit) |
| `tests/t6-sa-token.sh` | T6: productpage uses its ServiceAccount token against the API server | token usable in S0, blocked from S1; reading Secrets is denied by RBAC in every scenario |

Each run appends to `results/attacks.csv` and writes evidence as `results/<threat>-<scenario>-*`.
T2 captures on the node NIC inside VM `zt-w1`. The host bridge `bridge100` does not see VM-to-VM frames (`results/T2-S0-host-bridge.txt`).

The app is pinned to fixed nodes so every call crosses nodes: productpage and ratings on `zt-w1`, details, reviews and mongodb on `zt-w2`.

## Layout

| Path | Content |
|---|---|
| `infra/` | VM sizing, pinned versions, cluster bootstrap |
| `manifests/` | demo app and per-scenario controls (S1 to S3) |
| `tests/` | attack scripts mapped to threats T1 to T6 |
| `bench/` | fortio and iperf3 runners |
| `results/` | raw CSV, packet captures, logs |
| `scripts/` | aggregation and plotting |
| `docs/` | LaTeX report, bibliography, versions |
