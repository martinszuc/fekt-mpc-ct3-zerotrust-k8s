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
| A1 ratings data (MongoDB, no authentication) | mongodb pod |
| A2 review and rating content in transit | pod-to-pod HTTP and MongoDB wire protocol between nodes |
| A3 Kubernetes API (cluster state, Secrets) | API server on zt-cp, reachable from pods |
| A4 ServiceAccount tokens | mounted into every pod by default |

Trust boundaries: pod and pod (same namespace), node and node network, pod and API server.

## Attacker model

| ID | Position | Capability |
|---|---|---|
| AT1 | Code execution in productpage (the internet-facing frontend) | Runs arbitrary tools with the pod's network identity and mounted credentials |
| AT2 | On the node-to-node network | Passive capture of traffic between nodes (active MITM not tested) |
| AT3 | Can create pods in the `bookinfo` namespace (for example a leaked CI or developer credential) | Chooses pod labels and image, not the mesh certificate |

## Threats

STRIDE: Spoofing, Tampering, Repudiation, Information disclosure, Denial of service, Elevation of privilege.

| ID | Threat | Attacker | STRIDE | Asset | Control | Scenario |
|---|---|---|---|---|---|---|
| T1 | Frontend reads the database and calls a backend it never uses (lateral movement) | AT1 | E, I, T | A1 | Default-deny NetworkPolicy | S1 |
| T2 | Sniffing pod-to-pod traffic between nodes | AT2 | I (T if active) | A2 | Cilium WireGuard (node level) or mesh mTLS (workload level) | S2a, S2b |
| T3 | Rogue pod copies the trusted label (`app=reviews`) and calls ratings without a workload identity | AT3 | S | A1 | mTLS STRICT; not stopped by NetworkPolicy (labels are not identity) or WireGuard (authenticates nodes) | S2b |
| T4 | Authenticated workload calls an endpoint or method it does not need | AT1 | E | A1, A2 | L7 AuthorizationPolicy | S3 |
| T5 | Compromised pod with a valid identity on an allowed path | AT1 | S, T, I, E | A1, A2 | Not mitigated; documented limit | none |
| T6 | Pod's ServiceAccount token used against the API server | AT1 | S, E, I | A3, A4 | No token mounted, no route to the API server, least-privilege RBAC | S1 |

Not tested: Repudiation (only partly covered by Hubble flow logs from S1 and Envoy access logs from S2b) and Denial of service (out of scope).

## Expected and observed outcomes

Cells: expected outcome of the attack; `ok` = matched in `results/attacks.csv` (22.10), `-` = not run yet.

| Threat | S0 | S1 | S2a | S2b | S3 |
|---|---|---|---|---|---|
| T1 lateral movement | succeeds, ok | blocked, ok | blocked, ok | blocked, - | blocked, - |
| T2 sniffing | succeeds, ok | succeeds, ok | blocked, ok | blocked, - | blocked, - |
| T3 rogue pod | succeeds, ok | succeeds, ok | succeeds, ok | blocked, - | blocked, - |
| T4 disallowed endpoint | succeeds, - | succeeds, - | succeeds, - | succeeds, - | blocked, - |
| T5 valid identity | succeeds | succeeds | succeeds | succeeds | succeeds |
| T6 token abuse | succeeds, ok | blocked, ok | blocked, ok | blocked, - | blocked, - |

Notes from the evidence:

- T1: no credentials needed; productpage reads `test.ratings` directly. S1 drops are visible in Hubble (`Policy denied DROPPED`).
- T2: S0/S1 captures show review text and MongoDB queries inside VXLAN; S2a captures contain only WireGuard (UDP 51871).
- T3: shows why segmentation by labels is not authentication.
- T6: in S0 the token authenticates as `system:serviceaccount:bookinfo:bookinfo-productpage` but RBAC already denies reading Secrets (403); the threat is reconnaissance and a credential that works from outside the pod (token lifetime 1 year with the default token-expiration extension). S1 has two controls here: no token mounted and no network path to the API server.
- T4 and T5 tests are not written yet.
