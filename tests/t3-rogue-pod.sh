#!/usr/bin/env bash
# T3: rogue pod without a workload identity calls an internal service
# attacker can create pods in the namespace and copies the label NetworkPolicy trusts (app=reviews)
source "$(dirname "$0")/lib.sh"

case $SCENARIO in S0|S1|S2a) expect=succeeded ;; *) expect=blocked ;; esac
out=$RESULTS/T3-$SCENARIO-rogue-pod.txt
POD=rogue
# placed on zt-w2 so the call to ratings (zt-w1) crosses nodes
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait >/dev/null
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  labels:
    app: reviews                     # spoofed: allowed into ratings by S1
    sidecar.istio.io/inject: "false" # no mesh certificate, i.e. no workload identity
spec:
  nodeSelector: {kubernetes.io/hostname: lima-zt-w2}
  automountServiceAccountToken: false
  containers:
    - name: attacker
      image: registry.istio.io/release/examples-bookinfo-productpage-v1:1.20.3
      command: [sleep, "3600"]
      # never Ready, so the reviews Service never routes real traffic to it
      readinessProbe:
        exec: {command: ["false"]}
        periodSeconds: 60
YAML
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Running pod/"$POD" --timeout=3m >/dev/null
sleep 3   # Cilium identity for the new pod

res=$(kubectl -n "$NS" exec -i "$POD" -- python - http http://ratings:9080/ratings/0 < tests/probe.py 2>&1) \
  && observed=succeeded || observed=blocked
{ echo "## rogue pod (labels app=reviews, no sidecar, no SA token) -> ratings:9080"
  echo "$res"
  echo
  echo "## pod"
  kubectl -n "$NS" get pod "$POD" -o wide --show-labels
} > "$out"
kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null
record T3 rogue-pod-to-ratings "$expect" "$observed" "$out"
exit $FAILED
