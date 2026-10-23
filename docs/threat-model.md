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
| A1 ratings data (MongoDB, no authentication by upstream design, so network reachability is the only access control) | mongodb pod |
| A2 review and rating content in transit | pod-to-pod HTTP and MongoDB wire protocol between nodes |
| A3 Kubernetes API (cluster state, Secrets) | API server on zt-cp, reachable from pods |
| A4 ServiceAccount tokens | mounted into every pod by default |

Trust boundaries: pod and pod (same namespace), node and node network, pod and API server.

## Attacker model

| ID | Position | Capability |
|---|---|---|
| AT1 | Code execution in productpage (the internet-facing frontend) | Runs arbitrary tools with the pod's network identity and mounted credentials |
| AT2 | On the node-to-node network | Passive capture of traffic between nodes (active MITM not tested) |
| AT3 | Can create pods in the `bookinfo` namespace (for example a leaked CI or developer credential) | Chooses pod labels, image, sidecar injection and any ServiceAccount of the namespace |

## Threats

STRIDE: Spoofing, Tampering, Repudiation, Information disclosure, Denial of service, Elevation of privilege.

| ID | Threat | Attacker | STRIDE | Asset | Control | Scenario |
|---|---|---|---|---|---|---|
| T1 | Frontend reads the database and calls a backend it never uses (lateral movement) | AT1 | E, I, T | A1 | Default-deny NetworkPolicy | S1 |
| T2 | Sniffing pod-to-pod traffic between nodes | AT2 | I (T if active) | A2 | Cilium WireGuard (node level) or mesh mTLS (workload level) | S2a, S2b |
| T3 | Rogue pod copies the trusted label (`app=reviews`) and calls ratings; three variants below | AT3 | S | A1 | see T3 variants | S2b, S3, none |
| T4 | Compromised reviews (valid identity, allowed L4 path) calls ratings with a method it does not need (`POST /ratings/{id}`, write) | AT1 in reviews | E, T | A1 | L7 AuthorizationPolicy: only `GET /ratings/*` from principal `bookinfo-reviews` | S3 |
| T5 | Compromised reviews reads ratings with its own valid identity on an allowed path | AT1 in reviews | I | A1 | Not mitigated; documented limit | none |
| T6 | Pod's ServiceAccount token used against the API server | AT1 | S, E, I | A3, A4 | No token mounted, no route to the API server, least-privilege RBAC | S1 |

### T3 variants

Labels are chosen by whoever creates the pod, so they are not identity (S1). Mesh identity is the ServiceAccount, and AT3 can pick any ServiceAccount in the namespace, so mTLS alone does not stop a rogue pod that joins the mesh.

| Check | Rogue pod | Blocked by | Why |
|---|---|---|---|
| `rogue-no-identity` | outside the mesh (sidecar opted out), SA `default` | S2b mTLS STRICT | no certificate, plaintext rejected |
| `rogue-default-sa` | in the mesh, SA `default` | S3 authorization | valid certificate (authenticated) but not the allowed principal |
| `rogue-reused-sa` | in the mesh, SA `bookinfo-reviews` | none | indistinguishable from reviews; needs admission control or RBAC on pod creation and SA use (out of scope, limit) |

### Attribution of T6 checks

S1 adds two independent controls; each T6 check is decided by exactly one of them:

| Check | Decided by (S1+) |
|---|---|
| `token-mounted` | `automountServiceAccountToken: false` |
| `api-reachable` (anonymous, no token) | default-deny egress (no route to the API server) |
| `api-authenticated` | token absent (would also be stopped by default-deny egress) |
| `api-read-secrets` | RBAC (denied in every scenario, including S0) |

Both controls have no data-path cost, so they do not affect the S1 vs S0 measurement.

Not tested: Repudiation (only partly covered by Hubble flow logs from S1 and Envoy access logs from S2b) and Denial of service (out of scope).

## Expected and observed outcomes

Cells: expected outcome of the attack; `ok` = matched in `results/attacks.csv` (full rerun S0 to S2b 23.10), `-` = not run yet.

| Threat | S0 | S1 | S2a | S2b | S3 |
|---|---|---|---|---|---|
| T1 lateral movement | succeeds, ok | blocked, ok | blocked, ok | blocked, ok | blocked, - |
| T2 sniffing | succeeds, ok | succeeds, ok | blocked, ok | blocked, ok | blocked, - |
| T3 no-identity | succeeds, ok | succeeds, ok | succeeds, ok | blocked, ok | blocked, - |
| T3 default-sa | succeeds, ok | succeeds, ok | succeeds, ok | succeeds, ok | blocked, - |
| T3 reused-sa | succeeds, ok | succeeds, ok | succeeds, ok | succeeds, ok | succeeds, - |
| T4 disallowed method | succeeds, - | succeeds, - | succeeds, - | succeeds, - | blocked, - |
| T5 valid identity | succeeds, ok | succeeds, ok | succeeds, ok | succeeds, ok | succeeds, - |
| T6 token abuse | succeeds, ok | blocked, ok | blocked, ok | blocked, ok | blocked, - |

Notes from the evidence:

- T1: no credentials needed; productpage reads `test.ratings` directly. S1 drops are visible in Hubble (`Policy denied DROPPED`).
- T2: S0/S1 captures show review text and MongoDB queries inside VXLAN; S2a captures contain only WireGuard (UDP 51871). The verdict is about payload; the evidence also counts metadata (inner pod IPs and ports), which WireGuard hides but mesh mTLS leaves readable inside VXLAN (S2b capture: 224 frames with readable inner pod IPs and ports, 106 of them mTLS on the app ports; the TCP connections to istiod (15012) also show which pods are in the mesh; S2a: 0). WireGuard does not encrypt same-node traffic, mTLS does.
- T3: shows why segmentation by labels is not authentication, and (S2b) why authentication is not authorization. In S2b the pod outside the mesh fails with `Connection reset by peer` (sidecar rejects plaintext), while T1 still fails with a timeout and a Hubble `Policy denied` drop: two different controls, visible in the evidence.
- T5: the attacker runs as an ephemeral container in the real reviews pod, so it shares the pod's network identity and, from S2b, its sidecar.
- T6: in S0 the token authenticates as `system:serviceaccount:bookinfo:bookinfo-productpage` but RBAC already denies reading Secrets (403); the threat is reconnaissance and a credential that works from outside the pod (token lifetime 1 year with the default token-expiration extension). S1 has two controls here: no token mounted and no network path to the API server.
- T4 test is not written yet (needs S3); it will reuse the T5 ephemeral container. ratings-v2 answers `POST` with 501 (writes are only implemented for in-memory v1), so the verdict is whether the request reaches the application (any ratings response) or is rejected by the sidecar (403 `RBAC: access denied`), not whether data changes.
