#!/usr/bin/env bash
# installs or removes the Istio control plane: infra/istio.sh on|off
# CRDs (chart "base") stay installed when off: they run nothing
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env
# forced, never inherited: the default kubeconfig on the host points at another cluster
export KUBECONFIG=$PWD/$KUBECONFIG_PATH
[[ -f $KUBECONFIG ]] || { echo "missing $KUBECONFIG, run make up" >&2; exit 1; }
REPO=https://istio-release.storage.googleapis.com/charts
# istiod-values.yaml pins istiod to lima-zt-cp; other clusters override only that value
cp_selector=()
[[ $NODE_PREFIX$CP_NODE == lima-zt-cp ]] || cp_selector=(--set-string "nodeSelector.kubernetes\\.io/hostname=$NODE_PREFIX$CP_NODE")

case ${1:-} in
  on)
    helm upgrade --install istio-base base --repo "$REPO" --version "$ISTIO_VERSION" \
      -n istio-system --create-namespace --wait
    helm upgrade --install istiod istiod --repo "$REPO" --version "$ISTIO_VERSION" \
      -n istio-system -f manifests/s2b-mtls/istiod-values.yaml ${cp_selector[@]+"${cp_selector[@]}"} --wait --timeout 10m
    ;;
  off)
    if helm -n istio-system status istiod >/dev/null 2>&1; then
      helm -n istio-system uninstall istiod --wait
    fi
    ;;
  *) echo "usage: $0 on|off" >&2; exit 2 ;;
esac
