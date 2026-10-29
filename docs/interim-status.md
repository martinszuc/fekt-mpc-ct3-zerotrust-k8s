# Interim status, 27.10.2026

**Zero-trust access and access control in Kubernetes**, Martin Szuc (231284), MPC-CT3.
Repository: https://github.com/martinszuc/fekt-mpc-ct3-zerotrust-k8s

## Approach

Controlled experiment: each configuration adds exactly one defense, every attack test maps to a threat (`docs/threat-model.md`), every measurement to one defense (`docs/measurement-plan.md`).

| Assignment part | Covered by |
|---|---|
| Analysis of segmentation and authentication approaches | Analysis chapter with comparison table (planned) |
| Secure connection between isolated nodes | Cilium WireGuard between VMs (node encryption), compared with Istio mesh mTLS |
| Overhead measurement | fortio and iperf3 benchmarks per configuration |
| Access control | Segmentation and ServiceAccount hardening, L7 authorization |

## Done

- Cluster: 3 VMs (Lima, Ubuntu 24.04 arm64), k3s v1.36.5, Cilium 1.20.3 with kube-proxy replacement; `make up` reproduces it.
- App: Bookinfo with MongoDB, one version per service, every call crosses nodes.
- Configurations baseline, segmentation, node encryption and mesh mTLS: one `make` target each switches the cluster, `make test` runs all attacks and stores evidence (pcaps, Hubble drops, logs) in `results/`.

| Attack | Baseline | Segmentation + no SA token | + node encryption (WireGuard) | + mesh mTLS (Istio) |
|---|---|---|---|---|
| Lateral movement: frontend reads the database | succeeds | blocked | blocked | blocked |
| Network sniffing between nodes | plaintext | plaintext | encrypted, metadata hidden | encrypted, metadata visible |
| Identity spoofing: rogue pod outside the mesh | succeeds | succeeds | succeeds | blocked |
| Identity spoofing: rogue pod in the mesh, other ServiceAccount | succeeds | succeeds | succeeds | succeeds |
| Identity spoofing: rogue pod with stolen ServiceAccount | succeeds | succeeds | succeeds | succeeds |
| Compromised service with valid identity | succeeds | succeeds | succeeds | succeeds |
| ServiceAccount token abuse against the API | succeeds | blocked | blocked | blocked |

All 48 checks match the expected outcome (`results/attacks.csv`).
Key observations so far:

- NetworkPolicy trusts labels, and WireGuard authenticates nodes, not workloads, so a rogue pod with a copied label still gets through with node encryption.
- mTLS stops only the rogue pod outside the mesh. A rogue pod in the mesh is authenticated, so only L7 authorization can stop it. A rogue pod with the stolen ServiceAccount is not stopped by any configuration (needs admission control, documented as a limit).
- WireGuard hides who talks to whom on the node link; with mTLS the inner pod IPs and ports stay readable (224 frames in the mesh mTLS capture vs 0 with node encryption), including which pods connect to istiod.

## Since the interim check (29.10)

- Scope confirmed by the consultant on 27.10.
- L7 authorization done: Istio `AuthorizationPolicy` allow-nothing plus one ALLOW per workload (principal, method, path), `make s3`.
- New attack test, unauthorized operation: the compromised reviews pod writes ratings (`POST`); only L7 authorization stops it (403), while the same container can still read (`GET`, 200).
- With L7 authorization the rogue pod in the mesh with another ServiceAccount is blocked (403); the one with the stolen ServiceAccount still succeeds (limit).
- Tests hardened: network sniffing is "blocked" only with proof (traffic ran, capture shows only WireGuard or mTLS on the app ports), unlabeled rogue pod as negative control, every result row carries a run id and git commit, environment snapshot per configuration.
- Full rerun of all five configurations: all 70 checks match (`results/attacks.csv`).

## Decisions and findings

- Online Boutique has no arm64 images (releases v0.10.3 to v0.10.7); Bookinfo (Istio samples) is used instead.
- The host network bridge does not see traffic between VMs, so network sniffing is captured on the node interface inside the VM.
- Kubernetes NetworkPolicy trusts pod labels: anyone who can create a pod with the right label passes segmentation.
- Segmentation adds two controls (NetworkPolicy, no ServiceAccount token); each token abuse check is attributed to exactly one of them, and neither has a data-path cost.
- Cilium's Istio compatibility settings are part of the base configuration everywhere, so mesh mTLS changes only the mesh.
- Mesh mTLS will also be measured with mTLS disabled (sidecars only) to separate proxy cost from encryption cost.

## Next steps

| Until | Goal |
|---|---|
| 05.11 | ~~L7 authorization~~ (done 29.10), analysis chapter, benchmark harness |
| 20.11 | Benchmarks for all configurations, graphs, results chapter |
| 25.11 | Final text, bibliography (ČSN ISO 690), demo video |

## Questions

1. Does "isolated nodes" mean separate VMs/hosts, or are Kubernetes nodes on VMs sufficient?
2. Is there an expected technology stack, or is the choice free?
3. Deliverable: repository with reproducible scripts, VM images, or both?
4. Documentation language: Slovak or English?
