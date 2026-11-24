#!/usr/bin/env bash
# creates the 3-node kind cluster (infra/kind.yaml) with Cilium, for the attack tests only; safe to re-run
# later steps need the same environment: source infra/kind.env
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/kind.env
source infra/config.env
# forced, never inherited: the default kubeconfig on the host points at another cluster
export KUBECONFIG=$PWD/$KUBECONFIG_PATH
CLUSTER=zt

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

mkdir -p "$(dirname "$KUBECONFIG_PATH")"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "kind cluster $CLUSTER already exists"
else
  log "creating kind cluster $CLUSTER"
  kind create cluster --name "$CLUSTER" --config infra/kind.yaml --kubeconfig "$KUBECONFIG"
fi
kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
chmod 600 "$KUBECONFIG"

# the k3s server runs workloads (istiod is pinned to it); kind taints its control plane
kubectl taint node "$NODE_PREFIX$CP_NODE" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
# network sniffing captures on the node NIC; the node image has no tcpdump
for n in $NODES; do
  node_has_tcpdump=$(docker exec "$n" sh -c 'command -v tcpdump || true')
  [[ -n $node_has_tcpdump ]] || docker exec "$n" sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tcpdump >/dev/null'
done

log "installing Cilium $CILIUM_VERSION"
infra/cilium.sh
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl get nodes -o wide
log "cluster ready; export KUBECONFIG=$PWD/$KUBECONFIG_PATH; source infra/kind.env"
