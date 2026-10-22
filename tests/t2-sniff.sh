#!/usr/bin/env bash
# T2: attacker on the node network captures cross-node pod traffic
# captured on zt-w1's node NIC inside the VM: the host bridge never sees VM-to-VM frames
# (socket_vmnet switches them itself, see results/T2-S0-host-bridge.txt)
source "$(dirname "$0")/lib.sh"

case $SCENARIO in S0|S1) expect=succeeded ;; *) expect=blocked ;; esac
SECONDS_=${T2_SECONDS:-15}
NODE=zt-w1
MARKER=Reviewer1   # app data that must not be readable on the wire
base=$RESULTS/T2-$SCENARIO
pcap=$base-capture.pcap
rm -f "$base"-{capture,plaintext,encrypted,no-traffic}.{pcap,txt}

# udp covers VXLAN (8472) and WireGuard (51871) between nodes
limactl shell "$NODE" sudo timeout "$SECONDS_" tcpdump -i "$NODE_IFACE" -s 0 -U -w - udp 2>/dev/null > "$pcap" &
cap=$!
sleep 3
# legitimate user traffic: productpage -> details/reviews -> ratings -> mongodb, all cross-node
probe productpage-v1 http "http://localhost:9080/productpage?u=normal" >/dev/null
for _ in 1 2 3 4; do probe productpage-v1 http "http://localhost:9080/productpage?u=normal" >/dev/null; done
wait $cap || true

hits=$(tshark -r "$pcap" -Y "frame contains \"$MARKER\"" 2>/dev/null | wc -l | tr -d ' ')
# without any inter-node tunnel frames the capture proves nothing either way
tunnel=$(tshark -r "$pcap" -Y 'udp.port==8472 || udp.port==51871' 2>/dev/null | wc -l | tr -d ' ')
if [[ $hits -gt 0 ]]; then observed=succeeded; tag=plaintext
elif [[ $tunnel -gt 0 ]]; then observed=blocked; tag=encrypted
else observed=no-traffic; tag=no-traffic; fi
final=$base-$tag.pcap
mv "$pcap" "$final"
txt=${final%.pcap}.txt
{
  echo "capture: $NODE $NODE_IFACE, ${SECONDS_}s, filter udp"
  echo "frames total: $(tshark -r "$final" 2>/dev/null | wc -l | tr -d ' '), tunnel frames (8472/51871): $tunnel, frames containing \"$MARKER\": $hits"
  echo
  # verdict above is about payload; this is about metadata (who talks to whom, on which port)
  echo "## metadata exposure"
  echo "VXLAN frames with readable inner pod IP/TCP headers: $(tshark -r "$final" -d udp.port==8472,vxlan -Y 'vxlan && tcp' 2>/dev/null | wc -l | tr -d ' ')"
  echo "of which inner payload is TLS (mesh mTLS): $(tshark -r "$final" -d udp.port==8472,vxlan -Y 'vxlan && tls' 2>/dev/null | wc -l | tr -d ' ')"
  echo "inner pod-to-pod conversations (src dst dport):"
  tshark -r "$final" -d udp.port==8472,vxlan -Y 'vxlan && tcp.flags.syn==1 && tcp.flags.ack==0' -T fields -E occurrence=l \
    -e ip.src -e ip.dst -e tcp.dstport 2>/dev/null | sort -u | head -10
  echo
  echo "## outer protocols"
  tshark -r "$final" -q -z io,phs -d udp.port==8472,vxlan -d udp.port==51871,wg 2>/dev/null | sed -n '/^frame/,$p' | head -20
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
  echo
  echo "## cilium encryption status"
  cilium encryption status 2>&1
} > "$txt"
record T2 cross-node-sniff "$expect" "$observed" "$final"
exit $FAILED
