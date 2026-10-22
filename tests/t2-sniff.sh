#!/usr/bin/env bash
# T2: attacker on the node network captures cross-node pod traffic
# CAPTURE=node (default): tcpdump on zt-w1's node NIC inside the VM
# CAPTURE=host: tcpdump on the host socket_vmnet bridge (needs sudo on the host)
source "$(dirname "$0")/lib.sh"

case $SCENARIO in S0|S1) expect=succeeded ;; *) expect=blocked ;; esac
CAPTURE=${CAPTURE:-node}
SECONDS_=${T2_SECONDS:-15}
NODE=zt-w1
BRIDGE=bridge100
MARKER=Reviewer1   # app data that must not be readable on the wire
pcap=$RESULTS/T2-$SCENARIO-capture.pcap
rm -f "$RESULTS"/T2-"$SCENARIO"-{capture,plaintext,encrypted}.{pcap,txt}

# udp covers VXLAN (8472) and WireGuard (51871) between nodes
if [[ $CAPTURE == host ]]; then
  sudo timeout "$SECONDS_" tcpdump -i "$BRIDGE" -s 0 -U -w "$pcap" udp 2>/dev/null &
else
  limactl shell "$NODE" sudo timeout "$SECONDS_" tcpdump -i "$NODE_IFACE" -s 0 -U -w - udp 2>/dev/null > "$pcap" &
fi
cap=$!
sleep 3
# legitimate user traffic: productpage -> details/reviews -> ratings -> mongodb, all cross-node
probe productpage-v1 http "http://localhost:9080/productpage?u=normal" >/dev/null
for _ in 1 2 3 4; do probe productpage-v1 http "http://localhost:9080/productpage?u=normal" >/dev/null; done
wait $cap || true

hits=$(tshark -r "$pcap" -Y "frame contains \"$MARKER\"" 2>/dev/null | wc -l | tr -d ' ')
[[ $hits -gt 0 ]] && { observed=succeeded; tag=plaintext; } || { observed=blocked; tag=encrypted; }
final=$RESULTS/T2-$SCENARIO-$tag.pcap
mv "$pcap" "$final"
txt=${final%.pcap}.txt
{
  echo "capture: $CAPTURE ($([[ $CAPTURE == host ]] && echo "host $BRIDGE" || echo "$NODE $NODE_IFACE")), ${SECONDS_}s, filter udp"
  echo "frames total: $(tshark -r "$final" 2>/dev/null | wc -l | tr -d ' '), frames containing \"$MARKER\": $hits"
  echo
  echo "## outer protocols"
  tshark -r "$final" -q -z io,phs -d udp.port==8472,vxlan 2>/dev/null | sed -n '/^frame/,$p' | head -20
  echo
  echo "## decoded inner HTTP (src dst method uri status)"
  tshark -r "$final" -d udp.port==8472,vxlan -Y http -T fields -E occurrence=l \
    -e ip.src -e ip.dst -e http.request.method -e http.request.uri -e http.response.code 2>/dev/null | head -20
  echo
  echo "## readable payload containing \"$MARKER\""
  tshark -r "$final" -d udp.port==8472,vxlan -Y "frame contains \"$MARKER\"" -T fields -e http.file_data 2>/dev/null \
    | head -2 | while read -r h; do echo "$h" | xxd -r -p | cut -c1-300; echo; done
  echo
  echo "## decoded inner MongoDB (src dst opcode)"
  tshark -r "$final" -d udp.port==8472,vxlan -Y mongo -T fields -E occurrence=l \
    -e ip.src -e ip.dst -e mongo.opcode 2>/dev/null | head -6
} > "$txt"
record T2 cross-node-sniff "$expect" "$observed" "$final"
exit $FAILED
