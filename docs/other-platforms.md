# Other platforms

All results come from the macOS setup. Defaults in `infra/config.env` are the Mac values; everything below is an env override. Container images are multi-arch (CI runs on x86_64).

| Setup | How | Status |
|---|---|---|
| kind, attack tests only | `infra/up-kind.sh`, `source infra/kind.env`, then `make app`, `make s0` … `make test` (or `make reproduce`) | CI `attack-tests`, Linux x86_64: 70/70 (25.11) |
| Figures from committed data | `make plot`, `make deltas` (or the commands of CI job `plot`) | Mac; CI on Linux and Windows (Git Bash) |
| Linux host, Lima + QEMU | `VM_TYPE=qemu VM_ARCH=x86_64 VM_NETWORK=lima:user-v2 make up`; VMs must reach each other; set `NODE_IFACE` if the NIC is not `lima0` | untested |
| Own 3-node cluster | [below](#own-cluster) | untested |
| Windows | WSL2 (Ubuntu) as the Linux host | untested |

> [!WARNING]
> kind is not for benchmarks: nodes share the host kernel and one Docker bridge, so there is no real node-to-node link.

## Linux and WSL2

- **Tools**: kubectl, helm, cilium-cli, jq, tshark, git, make, python3 (+ `python3-venv`); for kind also Docker and kind. See the `Install tools` step in `.github/workflows/ci.yml`.
- **kind with 3 nodes**: `sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288`
- **Node encryption**: needs WireGuard in the host kernel.
- **WSL2**: clone inside the WSL file system; a Windows checkout breaks line endings.
- `make up` and `make vm-prep` are Lima only.

## Own cluster

Requirements:

- Cilium as the only CNI, no kube-proxy (see the k3s flags in `infra/up.sh`)
- tcpdump and passwordless sudo for the ssh user on the nodes
- W1 and W2 are different nodes; the control plane accepts pods (istiod runs there)

Put the kubeconfig at `.kube/config`, run `infra/cilium.sh`, then:

```bash
export NODE_EXEC=ssh NODE_SSH_USER=ubuntu       # extra flags in NODE_SSH_OPTS
export CP_NODE=cp W1_NODE=w1 W2_NODE=w2         # node names, also the ssh hosts
export NODE_IFACE=eth0                          # NIC that carries node-to-node traffic
```

`infra/apply.sh` and `infra/istio.sh` replace the pinned `lima-zt-*` node names with these at apply time.
