#!/usr/bin/env bash
# deletes the cluster and the local kubeconfig; safe to re-run
# NODE_EXEC=lima: the VMs; docker: the kind cluster; ssh (own cluster): nothing, its kubeconfig stays
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env

case $NODE_EXEC in
  lima)
    for n in $NODES; do
      if limactl list --format '{{.Name}}' "$n" >/dev/null 2>&1; then
        limactl delete --force "$n"
      fi
    done
    ;;
  docker)
    # --kubeconfig: kind would otherwise edit the default kubeconfig (another cluster on the host)
    kind delete cluster --name zt --kubeconfig "$PWD/$KUBECONFIG_PATH"
    ;;
  *) echo "NODE_EXEC=$NODE_EXEC: own cluster, nothing deleted" >&2; exit 0 ;;
esac
rm -f "$KUBECONFIG_PATH"
