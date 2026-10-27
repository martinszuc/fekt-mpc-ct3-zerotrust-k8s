# Threat model (STRIDE, draft 22.10.2026)

## System

Bookinfo on a 3-node k3s cluster (Cilium CNI, 3 Lima VMs on one socket_vmnet network).
Call graph, every hop crosses nodes:

```
client -> productpage (w1) -> details (w2)
                           -> reviews-v3 (w2) -> ratings-v2 (w1) -> mongodb (w2)
```

| Asset | Where |
|---|---|
| Ratings data (MongoDB, no authentication by upstream design, so network reachability is the only access control) | mongodb pod |
| Review and rating content in transit | pod-to-pod HTTP and MongoDB wire protocol between nodes |
| Kubernetes API (cluster state, Secrets) | API server on zt-cp, reachable from pods |
| ServiceAccount tokens | mounted into every pod by default |

Trust boundaries: pod and pod (same namespace), node and node network, pod and API server.

## Attacker model

| Attacker | Position | Capability |
|---|---|---|
| Compromised frontend | Code execution in productpage (the internet-facing frontend) | Runs arbitrary tools with the pod's network identity and mounted credentials |
| Network observer | On the node-to-node network | Passive capture of traffic between nodes (active MITM not tested) |
| Pod creator | Can create pods in the `bookinfo` namespace (for example a leaked CI or developer credential) | Chooses pod labels, image, sidecar injection and any ServiceAccount of the namespace |

## Defenses

Each configuration adds exactly one defense to its parent. Node encryption and mesh mTLS are alternatives, both built on segmentation.

| Configuration | Parent | Adds |
|---|---|---|
| Baseline | none | Cilium only, no policies, no mesh |
| Segmentation | Baseline | default-deny NetworkPolicy, no ServiceAccount tokens mounted |
| Node encryption | Segmentation | Cilium transparent encryption (WireGuard) between nodes |
| Mesh mTLS | Segmentation | Istio sidecars, `PeerAuthentication` STRICT |
| L7 authorization | Mesh mTLS | Istio `AuthorizationPolicy` |
| Mesh without mTLS | Segmentation | Istio sidecars, mTLS disabled; measurement only, no attack tests |

## Attacks

STRIDE: Spoofing, Tampering, Repudiation, Information disclosure, Denial of service, Elevation of privilege.

| Attack | Description | Attacker | STRIDE | Asset | Stopped by |
|---|---|---|---|---|---|
| Lateral movement | Frontend reads the database and calls a backend it never uses | Compromised frontend | E, I, T | ratings data | Segmentation |
| Network sniffing | Capture of pod-to-pod traffic between nodes | Network observer | I (T if active) | data in transit | Node encryption or mesh mTLS |
| Identity spoofing | Rogue pod copies the trusted label (`app=reviews`) and calls ratings; three variants below | Pod creator | S | ratings data | depends on the variant |
| Unauthorized operation | Compromised reviews (valid identity, allowed L4 path) calls ratings with a method it does not need (`POST /ratings/{id}`, write) | Compromised frontend, here in reviews | E, T | ratings data | L7 authorization: only `GET /ratings/*` from principal `bookinfo-reviews` |
| Compromised service | Compromised reviews reads ratings with its own valid identity on an allowed path | Compromised frontend, here in reviews | I | ratings data | none (documented limit) |
| Token abuse | Pod's ServiceAccount token used against the API server | Compromised frontend | S, E, I | Kubernetes API, tokens | Segmentation (no token mounted, no route to the API server), least-privilege RBAC |

### Identity spoofing variants

Labels are chosen by whoever creates the pod, so they are not identity (segmentation trusts them). Mesh identity is the ServiceAccount, and the pod creator can pick any ServiceAccount in the namespace, so mTLS alone does not stop a rogue pod that joins the mesh.

| Variant | Check | Rogue pod | Stopped by | Why |
|---|---|---|---|---|
| Outside the mesh | `rogue-no-identity` | sidecar opted out, SA `default` | Mesh mTLS (STRICT) | no certificate, plaintext rejected |
| Other ServiceAccount | `rogue-default-sa` | in the mesh, SA `default` | L7 authorization | valid certificate (authenticated) but not the allowed principal |
| Stolen ServiceAccount | `rogue-reused-sa` | in the mesh, SA `bookinfo-reviews` | none | indistinguishable from reviews; needs admission control or RBAC on pod creation and SA use (out of scope, limit) |

### Attribution of token abuse checks

Segmentation adds two independent controls; each token abuse check is decided by exactly one of them:

| Check | Decided by (segmentation and later) |
|---|---|
| `token-mounted` | `automountServiceAccountToken: false` |
| `api-reachable` (anonymous, no token) | default-deny egress (no route to the API server) |
| `api-authenticated` | token absent (would also be stopped by default-deny egress) |
| `api-read-secrets` | RBAC (denied in every configuration, including the baseline) |

Both controls have no data-path cost, so they do not affect the segmentation vs. baseline measurement.

Not tested: Repudiation (only partly covered by Hubble flow logs from segmentation on and Envoy access logs with the mesh) and Denial of service (out of scope).

## Expected and observed outcomes

Cells: expected outcome of the attack; `ok` = matched in `results/attacks.csv` (full rerun 23.10), `-` = not run yet.

| Attack | Baseline | Segmentation | Node encryption | Mesh mTLS | L7 authorization |
|---|---|---|---|---|---|
| Lateral movement | succeeds, ok | blocked, ok | blocked, ok | blocked, ok | blocked, - |
| Network sniffing | succeeds, ok | succeeds, ok | blocked, ok | blocked, ok | blocked, - |
| Spoofing, outside the mesh | succeeds, ok | succeeds, ok | succeeds, ok | blocked, ok | blocked, - |
| Spoofing, other ServiceAccount | succeeds, ok | succeeds, ok | succeeds, ok | succeeds, ok | blocked, - |
| Spoofing, stolen ServiceAccount | succeeds, ok | succeeds, ok | succeeds, ok | succeeds, ok | succeeds, - |
| Unauthorized operation | succeeds, - | succeeds, - | succeeds, - | succeeds, - | blocked, - |
| Compromised service | succeeds, ok | succeeds, ok | succeeds, ok | succeeds, ok | succeeds, - |
| Token abuse | succeeds, ok | blocked, ok | blocked, ok | blocked, ok | blocked, - |

Notes from the evidence:

- Lateral movement: no credentials needed; productpage reads `test.ratings` directly. With segmentation the drops are visible in Hubble (`Policy denied DROPPED`).
- Network sniffing: baseline and segmentation captures show review text and MongoDB queries inside VXLAN; node encryption captures contain only WireGuard (UDP 51871). The verdict is about payload; the evidence also counts metadata (inner pod IPs and ports), which WireGuard hides but mesh mTLS leaves readable inside VXLAN (mesh mTLS capture: 224 frames with readable inner pod IPs and ports, 106 of them mTLS on the app ports; the TCP connections to istiod (15012) also show which pods are in the mesh; node encryption: 0). WireGuard does not encrypt same-node traffic, mTLS does.
- Identity spoofing: shows why segmentation by labels is not authentication, and with mesh mTLS why authentication is not authorization. With mesh mTLS the pod outside the mesh fails with `Connection reset by peer` (sidecar rejects plaintext), while lateral movement still fails with a timeout and a Hubble `Policy denied` drop: two different controls, visible in the evidence.
- Compromised service: the attacker runs as an ephemeral container in the real reviews pod, so it shares the pod's network identity and, with the mesh, its sidecar.
- Token abuse: in the baseline the token authenticates as `system:serviceaccount:bookinfo:bookinfo-productpage` but RBAC already denies reading Secrets (403); the threat is reconnaissance and a credential that works from outside the pod (token lifetime 1 year with the default token-expiration extension). Segmentation has two controls here: no token mounted and no network path to the API server.
- Unauthorized operation: test not written yet (needs L7 authorization); it will reuse the compromised service ephemeral container. ratings-v2 answers `POST` with 501 (writes are only implemented for in-memory v1), so the verdict is whether the request reaches the application (any ratings response) or is rejected by the sidecar (403 `RBAC: access denied`), not whether data changes.

## Codes used in the repository

Scripts, `make` targets and evidence files use short codes. This table is the only mapping:

| Code | Name | `make` target / manifests | Test script |
|---|---|---|---|
| S0 | Baseline | `make s0` | |
| S1 | Segmentation | `make s1`, `manifests/s1-segmentation/` | |
| S2a | Node encryption | `make s2a`, `manifests/s2a-wireguard/` | |
| S2b | Mesh mTLS | `make s2b`, `manifests/s2b-mtls/` | |
| S2b-plain | Mesh without mTLS | planned | |
| S3 | L7 authorization | planned, `manifests/s3-authz/` | |
| T1 | Lateral movement | | `tests/t1-lateral.sh` |
| T2 | Network sniffing | | `tests/t2-sniff.sh` |
| T3 | Identity spoofing | | `tests/t3-rogue-pod.sh` |
| T4 | Unauthorized operation | | planned |
| T5 | Compromised service | | `tests/t5-valid-identity.sh` |
| T6 | Token abuse | | `tests/t6-sa-token.sh` |

Evidence is named `results/<attack code>-<configuration code>-*`, for example `results/T2-S2a-encrypted.pcap` is network sniffing with node encryption.
