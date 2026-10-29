# Pinned versions

Recorded 22.10.2026, host drift and kernels rechecked 29.10.2026. Change only between experiment runs, never within one. Each test run records the live state in `results/env-<configuration code>.txt`.

## Host

| Item | Version |
|---|---|
| Hardware | MacBook Pro Mac16,8, Apple M4 Pro (10P + 4E cores), 48 GB RAM |
| macOS | 26.7.2 (25G330) since 29.10 (26.7.1 (25G313) until 23.10) |
| Homebrew | 7.0.10 |

## Cluster

| Component | Version | Pinned in |
|---|---|---|
| Lima | 2.2.1 | host tool |
| VM image | Ubuntu 24.04 arm64 (Lima `template:ubuntu-24.04`) | `infra/config.env` |
| VM type / network | vz, socket_vmnet 1.2.2 `lima:shared` (192.168.105.0/24) | `infra/config.env` |
| VM sizing | 3 nodes, each 4 vCPU / 8 GiB / 30 GiB | `infra/config.env` |
| VM kernel | zt-cp, zt-w1: 6.8.0-142-generic; zt-w2: 6.8.0-147-generic since 29.10 (unattended-upgrades installed it 23.10, active after the next boot). Not pinned yet; align before benchmarks | not pinned |
| k3s | v1.36.5+k3s1 | `infra/config.env` |
| Cilium | 1.20.3 (Helm chart); kube-proxy replacement, VXLAN, `socketLB.hostNamespaceOnly: true`, `cni.exclusive: false` (Istio compatibility, all configurations) | `infra/config.env`, `infra/cilium-values.yaml` |
| Node encryption | Cilium WireGuard, in-kernel module (Linux 6.8.0), pod traffic only (`nodeEncryption: false`), `cilium_wg0` MTU 1405 | `manifests/s2a-wireguard/` |
| Service mesh | Istio 1.30.7 (Helm charts `base`, `istiod`), sidecar mode, native sidecars, init-container redirect (no istio-cni), istiod on zt-cp; 1.31.x charts not yet published in the Helm repo (23.10) | `infra/config.env`, `manifests/s2b-mtls/` |
| L7 authorization | Istio `AuthorizationPolicy` (security.istio.io/v1), same Istio version | `manifests/s3-authz/` |
| Demo app | Bookinfo from Istio samples tag 1.31.3, images 1.20.3 (productpage-v1, details-v1, reviews-v3, ratings-v2) | `manifests/app/upstream/` |
| Database | Bookinfo MongoDB image 1.20.3 (mongod v8.0.8) | `manifests/app/upstream/` |

## Host tools

| Tool | Version |
|---|---|
| kubectl | v1.37.1 (v1.37.0 until 23.10) |
| helm | v4.3.1 (v4.2.4 until 23.10) |
| cilium-cli | v0.20.1 |
| hubble | 1.20.2 |
| fortio | 1.76.0 |
| iperf3 | 3.22 |
| tshark (Wireshark) | 4.6.9 |
| jq / yq | Homebrew current |
| python3 | 3.15.0 (3.14.7 until 23.10) |
