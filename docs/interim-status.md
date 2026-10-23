# Interim status, 27.10.2026

**Zero-trust access and access control in Kubernetes**, Martin Szuc (231284), MPC-CT3.
Repository: https://github.com/martinszuc/fekt-mpc-ct3-zerotrust-k8s

## Approach

Controlled experiment: each scenario adds exactly one control, every attack test maps to a threat (T1 to T6, `docs/threat-model.md`), every measurement to one control (`docs/measurement-plan.md`).

| Assignment part | Covered by |
|---|---|
| Analysis of segmentation and authentication approaches | Analysis chapter with comparison table (planned) |
| Secure connection between isolated nodes | S2a Cilium WireGuard between VMs, compared with S2b mesh mTLS |
| Overhead measurement | fortio and iperf3 benchmarks per scenario |
| Access control | S1 segmentation and ServiceAccount hardening, S3 L7 authorization |

## Done

- Cluster: 3 VMs (Lima, Ubuntu 24.04 arm64), k3s v1.36.5, Cilium 1.20.3 with kube-proxy replacement; `make up` reproduces it.
- App: Bookinfo with MongoDB, one version per service, every call crosses nodes.
- Scenarios S0, S1, S2a, S2b: `make s0|s1|s2a|s2b` switches the cluster, `make test` runs all attacks and stores evidence (pcaps, Hubble drops, logs) in `results/`.

| Threat | S0 baseline | S1 segmentation + no SA token | S2a + WireGuard | S2b + Istio mTLS |
|---|---|---|---|---|
| T1 frontend reads database directly | succeeds | blocked | blocked | blocked |
| T2 sniffing traffic between nodes | plaintext | plaintext | encrypted, metadata hidden | encrypted, metadata visible |
| T3 rogue pod outside the mesh | succeeds | succeeds | succeeds | blocked |
| T3 rogue pod in the mesh (SA default) | succeeds | succeeds | succeeds | succeeds |
| T3 rogue pod reusing the legitimate SA | succeeds | succeeds | succeeds | succeeds |
| T5 attacker inside a legitimate pod | succeeds | succeeds | succeeds | succeeds |
| T6 ServiceAccount token against API | succeeds | blocked | blocked | blocked |

All 48 checks match the expected outcome (`results/attacks.csv`).
Key observations so far:

- NetworkPolicy trusts labels, and WireGuard authenticates nodes, not workloads, so T3 still works in S2a.
- mTLS stops only the rogue pod outside the mesh. A rogue pod in the mesh is authenticated, so only authorization (S3) can stop it. A rogue pod reusing the legitimate ServiceAccount is not stopped by any scenario (needs admission control, documented as a limit).
- WireGuard hides who talks to whom on the node link; with mTLS the inner pod IPs and ports stay readable (224 frames in the S2b capture vs 0 in S2a), including which pods connect to istiod.

## Decisions and findings

- Online Boutique has no arm64 images (releases v0.10.3 to v0.10.7); Bookinfo (Istio samples) is used instead.
- The host network bridge does not see traffic between VMs, so T2 is captured on the node interface inside the VM.
- Kubernetes NetworkPolicy trusts pod labels: anyone who can create a pod with the right label passes S1 (T3).
- S1 adds two controls (segmentation, no ServiceAccount token); each T6 check is attributed to exactly one of them, and neither has a data-path cost.
- Cilium's Istio compatibility settings are part of the base configuration in every scenario, so S2b changes only the mesh.
- S2b will also be measured with mTLS disabled (sidecars only) to separate proxy cost from encryption cost.

## Next steps

| Until | Goal |
|---|---|
| 05.11 | S3 L7 authorization (T3 in-mesh, T4), analysis chapter |
| 20.11 | Benchmarks for all scenarios, graphs, results chapter |
| 25.11 | Final text, bibliography (ČSN ISO 690), demo video |

## Questions

1. Does "isolated nodes" mean separate VMs/hosts, or are Kubernetes nodes on VMs sufficient?
2. Is there an expected technology stack, or is the choice free?
3. Deliverable: repository with reproducible scripts, VM images, or both?
4. Documentation language: Slovak or English?
