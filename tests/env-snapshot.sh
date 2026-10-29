#!/usr/bin/env bash
# records the environment of a test run: results/env-<scenario>.txt (overwritten per run)
source "$(dirname "$0")/lib.sh"

out=$RESULTS/env-$SCENARIO.txt
section() { printf '\n## %s\n' "$1"; }
{
  echo "scenario $SCENARIO, run_id $RUN_ID, git $GIT_SHA, $(date -u +%FT%TZ)"
  section "host"
  echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
  limactl --version
  kubectl version --client 2>/dev/null | sed -n 1p
  echo "helm $(helm version --short)"
  cilium version --client 2>/dev/null | sed -n 1p
  tshark --version | sed -n 1p
  section "VMs"
  limactl list
  section "nodes"
  kubectl get nodes -o wide
  for n in $NODES; do
    section "node $n"
    limactl shell "$n" uname -a
    # MTUs decide the encapsulation overhead; cilium_wg0 exists only with WireGuard
    limactl shell "$n" sh -c "ip -o link show | awk '/$NODE_IFACE|cilium_|lxc/ {print \$2, \$4, \$5}' | grep -v '^lxc' || true"
  done
  section "cilium"
  kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
  # the VMs have no wireguard-tools; the agents report the WireGuard state
  cilium encryption status 2>&1
  # the key is absent unless WireGuard was ever enabled
  echo "enable-wireguard=$(kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-wireguard}') (empty: off)"
  kubectl -n kube-system get cm cilium-config -o json | jq -r '.data | to_entries[] | select(.key != "enable-wireguard")
    | select(.key | test("encrypt|wireguard|tunnel|routing-mode|kube-proxy-replacement|mtu|cni-exclusive|bpf-lb-sock-hostns|policy-enforcement"))
    | "\(.key)=\(.value)"'
  section "istio"
  helm -n istio-system list 2>/dev/null || true
  kubectl -n istio-system get deploy -o jsonpath='{range .items[*]}{.metadata.name} {.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null || true
  section "policies in $NS"
  kubectl -n "$NS" get networkpolicies 2>&1
  kubectl -n "$NS" get peerauthentications.security.istio.io,authorizationpolicies.security.istio.io 2>&1 || true
  echo "namespace labels: $(kubectl get ns "$NS" -o jsonpath='{.metadata.labels}')"
  section "workloads in $NS"
  kubectl -n "$NS" get pods -o json | jq -r '.items[] | select(.metadata.name | startswith("rogue-") | not)
    | "\(.metadata.name) node=\(.spec.nodeName) sa=\(.spec.serviceAccountName)",
      ((.status.containerStatuses + (.status.initContainerStatuses // []))[] | "  \(.name) \(.imageID)")'
} > "$out" 2>&1
echo "env snapshot: $out"
