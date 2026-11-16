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
Type "export PS1='$ ' RESULTS=results/demo KUBECONFIG=$PWD/.kube/config; mkdir -p results/demo; source demo/caption.sh; clear" Enter
Sleep 1s
Show

Hide
Type "c 1" Enter
Show
Sleep 2s
Sleep 2s

# baseline
Hide
Type "make s0 >/dev/null 2>&1; clear" Enter
Wait@20m /^\$ ?$/
Show
Hide
Type "c 2" Enter
Show
Sleep 2s
Type "tests/t1-lateral.sh" Enter
Wait@5m /^\$ ?$/
Sleep 3s
Hide
Type "c 3" Enter
Show
Sleep 2s
Type "tests/t2-sniff.sh && head -4 results/demo/T2-S0-plaintext.txt" Enter
Wait@5m /^\$ ?$/
Sleep 4s
Hide
Type "c 4" Enter
Show
Sleep 2s
Type "tests/t6-sa-token.sh" Enter
Wait@5m /^\$ ?$/
Sleep 4s

# segmentation
Hide
Type "make s1 >/dev/null 2>&1; clear" Enter
Wait@20m /^\$ ?$/
Show
Hide
Type "c 5" Enter
Show
Sleep 2s
Type "tests/t1-lateral.sh" Enter
Wait@5m /^\$ ?$/
Sleep 3s
Type "tests/t6-sa-token.sh" Enter
Wait@5m /^\$ ?$/
Sleep 3s
Hide
Type "c 6" Enter
Show
Sleep 2s
Type "tests/t2-sniff.sh && head -4 results/demo/T2-S1-plaintext.txt" Enter
Wait@5m /^\$ ?$/
Sleep 4s

# node encryption
Hide
Type "make s2a >/dev/null 2>&1; clear" Enter
Wait@20m /^\$ ?$/
Show
Hide
Type "c 7" Enter
Show
Sleep 2s
Type "tests/t2-sniff.sh && head -4 results/demo/T2-S2a-encrypted.txt" Enter
Wait@5m /^\$ ?$/
Sleep 4s
Hide
Type "c 8" Enter
Show
Sleep 2s
Type "tests/t3-rogue-pod.sh" Enter
Wait@10m /^\$ ?$/
Sleep 4s

# mesh mTLS
Hide
Type "make s2b >/dev/null 2>&1; clear" Enter
Wait@20m /^\$ ?$/
Show
Hide
Type "c 9" Enter
Show
Sleep 2s
Type "tests/t3-rogue-pod.sh" Enter
Wait@10m /^\$ ?$/
Sleep 4s
Hide
Type "c 10" Enter
Show
Sleep 2s
Type "tests/t2-sniff.sh && sed -n '3,9p' results/demo/T2-S2b-encrypted.txt" Enter
Wait@5m /^\$ ?$/
Sleep 5s

# L7 authorization
Hide
Type "make s3 >/dev/null 2>&1; clear" Enter
Wait@20m /^\$ ?$/
Show
Hide
Type "c 11" Enter
Show
Sleep 2s
Type "tests/t3-rogue-pod.sh" Enter
Wait@10m /^\$ ?$/
Sleep 4s
Type "tests/t4-unauthorized-op.sh && head -2 results/demo/T4-S3-unauthorized-op.txt" Enter
Wait@5m /^\$ ?$/
Sleep 4s
Hide
Type "c 12" Enter
Show
Sleep 2s
Type "tests/t5-valid-identity.sh" Enter
Wait@5m /^\$ ?$/
Sleep 6s
