#!/usr/bin/env bash
# kubectl apply -k <dir>, with the node names from infra/config.env in place of the lima-zt-* names
# in the manifests; with the default names it is exactly kubectl apply -k
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env
# forced, never inherited: the default kubeconfig on the host points at another cluster
export KUBECONFIG=$PWD/$KUBECONFIG_PATH
[[ -f $KUBECONFIG ]] || { echo "missing $KUBECONFIG, run make up" >&2; exit 1; }
dir=${1:?usage: infra/apply.sh <kustomize dir>}

expr=()
for pair in "zt-cp $CP_NODE" "zt-w1 $W1_NODE" "zt-w2 $W2_NODE"; do
  set -- $pair
  from=lima-$1 to=$NODE_PREFIX$2
  [[ $from == "$to" ]] || expr+=(-e "s#^\( *kubernetes\.io/hostname: \)$from\$#\1$to#")
done
if ((${#expr[@]} == 0)); then exec kubectl apply -k "$dir"; fi
kubectl kustomize "$dir" | sed "${expr[@]}" | kubectl apply -f -
