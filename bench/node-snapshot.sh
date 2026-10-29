#!/bin/sh
# runs on a node: limactl shell <vm> sh -s < bench/node-snapshot.sh
# CPU and memory counters of the node and of every container cgroup under kubepods, read directly
# (the kubelet resource endpoint caches cgroup stats for ~10 s, too coarse for short runs)
set -eu
echo "ts $(date +%s.%N)"
echo "hz $(getconf CLK_TCK)"
# busy jiffies: user nice system irq softirq; idle, iowait and steal excluded
awk '/^cpu /{print "cpu", $2 + $3 + $4 + $7 + $8}' /proc/stat
awk '/^MemTotal:/{t = $2} /^MemAvailable:/{a = $2} END{print "mem", (t - a) * 1024}' /proc/meminfo
# cg <dir> <usage_usec> <memory.current> <inactive_file>; mapped to containers on the host by container ID
find /sys/fs/cgroup -path '*kubepods*' -name cpu.stat | awk '{
  d = $0; sub(/\/cpu\.stat$/, "", d); u = 0; m = 0; i = 0
  while ((getline l < $0) > 0) if (l ~ /^usage_usec /) { split(l, a, " "); u = a[2] }
  close($0)
  f = d "/memory.current"; if ((getline l < f) > 0) m = l; close(f)
  f = d "/memory.stat"; while ((getline l < f) > 0) if (l ~ /^inactive_file /) { split(l, a, " "); i = a[2] }
  close(f)
  print "cg", d, u, m, i
}'
