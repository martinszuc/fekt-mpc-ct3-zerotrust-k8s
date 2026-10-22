#!/usr/bin/env bash
# installs or reconfigures Cilium: infra/cilium.sh [extra values file...]
# agents are restarted when cilium-config changes (chart default rollOutCiliumPods=false)
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env
export KUBECONFIG=${KUBECONFIG:-$PWD/$KUBECONFIG_PATH}

CP_IP=$(kubectl get node "lima-$CP_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
args=(-f infra/cilium-values.yaml)
for f in "$@"; do args+=(-f "$f"); done

config() { kubectl -n kube-system get cm cilium-config -o jsonpath='{.data}' 2>/dev/null || true; }
before=$(config)
helm upgrade --install cilium cilium \
  --repo https://helm.cilium.io --version "$CILIUM_VERSION" \
  --namespace kube-system "${args[@]}" \
  --set k8sServiceHost="$CP_IP" \
  --set devices="{$NODE_IFACE}" \
  --wait --timeout 10m
if [[ -n $before && $(config) != "$before" ]]; then
  kubectl -n kube-system rollout restart ds/cilium
  kubectl -n kube-system rollout status ds/cilium --timeout=10m
fi
cilium status --wait --wait-duration 10m >/dev/null
