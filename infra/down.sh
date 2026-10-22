#!/usr/bin/env bash
# deletes all cluster VMs and the local kubeconfig; safe to re-run
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env

for n in $NODES; do
  if limactl list --format '{{.Name}}' "$n" >/dev/null 2>&1; then
    limactl delete --force "$n"
  fi
done
rm -f "$KUBECONFIG_PATH"
