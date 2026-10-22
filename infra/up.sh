#!/usr/bin/env bash
# creates the 3-node Lima + k3s + Cilium cluster; safe to re-run
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

vm_status() { limactl list --format '{{.Status}}' "$1" 2>/dev/null || true; }

node_ip() {
  limactl shell "$1" ip -4 -o addr show "$NODE_IFACE" | awk '{print $4}' | cut -d/ -f1
}

ensure_vm() {
  local name=$1
  case "$(vm_status "$name")" in
    Running) log "$name already running" ;;
    Stopped) log "starting $name"; limactl start --tty=false "$name" ;;
    *)
      log "creating $name"
      limactl create --tty=false --name "$name" \
        --vm-type vz --arch aarch64 --plain \
        --cpus "$VM_CPUS" --memory "$VM_MEMORY_GIB" --disk "$VM_DISK_GIB" \
        --network "$VM_NETWORK" \
        "$LIMA_TEMPLATE"
      limactl start --tty=false "$name"
      ;;
  esac
}

k3s_active() { limactl shell "$1" systemctl is-active --quiet "$2" 2>/dev/null; }

install_server() {
  local ip=$1
  if k3s_active "$CP_NODE" k3s; then log "k3s server already active on $CP_NODE"; return; fi
  log "installing k3s $K3S_VERSION server on $CP_NODE ($ip)"
  limactl shell "$CP_NODE" sh -c "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='$K3S_VERSION' sh -s - server \
    --node-ip=$ip --advertise-address=$ip --tls-san=$ip \
    --flannel-backend=none --disable-network-policy --disable-kube-proxy \
    --disable=traefik,servicelb \
    --write-kubeconfig-mode=644"
}

install_agent() {
  local name=$1 ip=$2 cp_ip=$3 token=$4
  if k3s_active "$name" k3s-agent; then log "k3s agent already active on $name"; return; fi
  log "installing k3s $K3S_VERSION agent on $name ($ip)"
  limactl shell "$name" sh -c "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='$K3S_VERSION' \
    K3S_URL='https://$cp_ip:6443' K3S_TOKEN='$token' sh -s - agent --node-ip=$ip"
}

for n in $NODES; do ensure_vm "$n"; done

CP_IP=$(node_ip "$CP_NODE")
install_server "$CP_IP"

log "waiting for API server"
until limactl shell "$CP_NODE" sudo k3s kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done

TOKEN=$(limactl shell "$CP_NODE" sudo cat /var/lib/rancher/k3s/server/node-token)
for n in $NODES; do
  [[ $n == "$CP_NODE" ]] && continue
  install_agent "$n" "$(node_ip "$n")" "$CP_IP" "$TOKEN"
done

log "writing kubeconfig to $KUBECONFIG_PATH"
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
limactl shell "$CP_NODE" cat /etc/rancher/k3s/k3s.yaml \
  | sed "s#https://127.0.0.1:6443#https://$CP_IP:6443#" > "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"
export KUBECONFIG="$PWD/$KUBECONFIG_PATH"

log "installing Cilium $CILIUM_VERSION"
helm upgrade --install cilium cilium \
  --repo https://helm.cilium.io --version "$CILIUM_VERSION" \
  --namespace kube-system \
  -f infra/cilium-values.yaml \
  --set k8sServiceHost="$CP_IP" \
  --set devices="{$NODE_IFACE}" \
  --wait --timeout 10m

cilium status --wait --wait-duration 10m
kubectl wait --for=condition=Ready nodes --all --timeout=5m
kubectl get nodes -o wide
log "cluster ready; export KUBECONFIG=$PWD/$KUBECONFIG_PATH"
