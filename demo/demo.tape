# attack demo across the five configurations: make demo (needs a running cluster with the app, ~25 min)
# configuration switches are hidden; evidence goes to results/demo/, not to results/
Output results/demo/demo.mp4

Set Shell bash
Set FontSize 20
Set Width 1600
Set Height 900
Set Padding 30
Set TypingSpeed 35ms
Set Theme "Builtin Solarized Light"

Hide
Type "export PS1='$ ' RESULTS=results/demo KUBECONFIG=$PWD/.kube/config; mkdir -p results/demo; clear" Enter
Sleep 1s
Show

Type "# Zero-trust v Kubernetes: útoky v piatich konfiguráciách (Bookinfo, 3 uzly, Cilium)" Sleep 1s Enter
Sleep 2s

# baseline
Hide
Type "make s0 >/dev/null 2>&1; clear" Enter
Wait@20m /\$ $/
Show
Type "# 1/5 Bez ochrany: kompromitovaný frontend číta MongoDB priamo (laterálny pohyb)" Sleep 500ms Enter
Type "tests/t1-lateral.sh" Enter
Wait@5m /\$ $/
Sleep 3s
Type "# odpočúvanie siete medzi uzlami: obsah recenzií je čitateľný" Sleep 500ms Enter
Type "tests/t2-sniff.sh && head -4 results/demo/T2-S0-plaintext.txt" Enter
Wait@5m /\$ $/
Sleep 4s
Type "# ServiceAccount token frontendu funguje proti API serveru" Sleep 500ms Enter
Type "tests/t6-sa-token.sh" Enter
Wait@5m /\$ $/
Sleep 4s

# segmentation
Hide
Type "make s1 >/dev/null 2>&1; clear" Enter
Wait@20m /\$ $/
Show
Type "# 2/5 Segmentácia siete: default-deny NetworkPolicy, bez tokenov v podoch" Sleep 500ms Enter
Type "tests/t1-lateral.sh" Enter
Wait@5m /\$ $/
Sleep 3s
Type "tests/t6-sa-token.sh" Enter
Wait@5m /\$ $/
Sleep 3s
Type "# prevádzka je však stále nešifrovaná" Sleep 500ms Enter
Type "tests/t2-sniff.sh && head -4 results/demo/T2-S1-plaintext.txt" Enter
Wait@5m /\$ $/
Sleep 4s

# node encryption
Hide
Type "make s2a >/dev/null 2>&1; clear" Enter
Wait@20m /\$ $/
Show
Type "# 3/5 Šifrovanie medzi uzlami (Cilium WireGuard): len UDP 51871, žiadny obsah" Sleep 500ms Enter
Type "tests/t2-sniff.sh && head -4 results/demo/T2-S2a-encrypted.txt" Enter
Wait@5m /\$ $/
Sleep 4s
Type "# WireGuard autentizuje uzly, nie workloady: podvrhnutý pod so skopírovaným labelom prejde" Sleep 500ms Enter
Type "tests/t3-rogue-pod.sh" Enter
Wait@10m /\$ $/
Sleep 4s

# mesh mTLS
Hide
Type "make s2b >/dev/null 2>&1; clear" Enter
Wait@20m /\$ $/
Show
Type "# 4/5 mTLS medzi službami (Istio STRICT): pod mimo mesh je odmietnutý, pod s iným SA prejde" Sleep 500ms Enter
Type "tests/t3-rogue-pod.sh" Enter
Wait@10m /\$ $/
Sleep 4s
Type "# obsah je šifrovaný, adresy a porty podov ostávajú čitateľné" Sleep 500ms Enter
Type "tests/t2-sniff.sh && sed -n '3,9p' results/demo/T2-S2b-encrypted.txt" Enter
Wait@5m /\$ $/
Sleep 5s

# L7 authorization
Hide
Type "make s3 >/dev/null 2>&1; clear" Enter
Wait@20m /\$ $/
Show
Type "# 5/5 L7 autorizácia (AuthorizationPolicy): zastaví iný SA aj neoprávnenú operáciu" Sleep 500ms Enter
Type "tests/t3-rogue-pod.sh" Enter
Wait@10m /\$ $/
Sleep 4s
Type "tests/t4-unauthorized-op.sh && head -2 results/demo/T4-S3-unauthorized-op.txt" Enter
Wait@5m /\$ $/
Sleep 4s
Type "# obmedzenie: útočník s platnou identitou a povolenou cestou prejde vždy" Sleep 500ms Enter
Type "tests/t5-valid-identity.sh" Enter
Wait@5m /\$ $/
Sleep 6s
