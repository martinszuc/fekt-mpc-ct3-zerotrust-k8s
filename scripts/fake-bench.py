#!/usr/bin/env python3
"""Dry run of the benchmark pipeline without a cluster (stdlib only).

Writes synthetic fortio/iperf3 JSON, node snapshots (bench/node-snapshot.sh format) and pod lists,
and feeds them through bench/record.py with the same arguments as bench/run.sh.
Then: make plot BENCH_DIR=results/bench-fake

scripts/fake-bench.py [--out results/bench-fake] [--runs 2]
"""
import argparse
import json
import os
import random
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench"))
import record as recorder  # noqa: E402

SCENARIOS = ["S0", "S1", "S2a", "S2b-plain", "S2b", "S3"]
# relative cost per configuration: latency factor, throughput factor, extra node CPU
COST = {"S0": (1.0, 1.0, 0), "S1": (1.02, 0.99, 10), "S2a": (1.15, 0.7, 120), "S2b-plain": (1.6, 0.6, 250),
        "S2b": (1.8, 0.5, 320), "S3": (1.9, 0.48, 340)}
NODES = ["lima-zt-cp", "lima-zt-w1", "lima-zt-w2"]
MESH = ("S2b-plain", "S2b", "S3")


def cid(name):
    return f"{abs(hash(name)):064x}"[-64:]


def pods(scen):
    """kubectl get pods -A -o json with the containers record.py keeps (and one it must drop)"""
    spec = [("bookinfo", "bench-client-7d9f-abcde", ["fortio", "iperf3"]),
            ("bookinfo", "fortio-same-5c6b-fghij", ["fortio"]), ("bookinfo", "fortio-cross-5c6b-klmno", ["fortio"]),
            ("bookinfo", "productpage-v1-6f8-pqrst", ["productpage"]), ("bookinfo", "ratings-v2-7a1-uvwxy", ["ratings"]),
            ("kube-system", "cilium-x1y2z", ["cilium-agent"]), ("kube-system", "coredns-abc", ["coredns"])]
    if scen in MESH:
        spec.append(("istio-system", "istiod-123", ["discovery"]))
    items = []
    for ns, pod, cs in spec:
        if ns == "bookinfo" and scen in MESH:
            cs = cs + ["istio-proxy"]
        items.append({"metadata": {"namespace": ns, "name": pod}, "status": {
            "containerStatuses": [{"name": c, "containerID": f"containerd://{cid(scen + pod + c)}"} for c in cs]}})
    return {"items": items}, [(ns, p, c) for ns, p, cs in [(i["metadata"]["namespace"], i["metadata"]["name"],
                              [c["name"] for c in i["status"]["containerStatuses"]]) for i in items] for c in cs]


def snapshot(path, scen, containers, t, usage, load_mc, dt):
    """advance cumulative counters by dt seconds at the given load and write one snapshot"""
    with open(path, "w") as f:
        for n in NODES:
            usage[n] = usage.get(n, 0) + (300 + load_mc) * dt / 1000 * 100
            f.write(f"# zt-node {n}\nts {t:.6f}\nhz 100\ncpu {usage[n]:.0f}\nmem {3.1 * 2**30:.0f}\n")
            f.write(f"cg /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-pod{n[-2:]}.slice 1 1 0\n")
            for ns, pod, c in containers:
                key = (n, pod, c)
                rate = 5 + (load_mc / 4 if c in ("fortio", "iperf3", "istio-proxy") else 2)
                usage[key] = usage.get(key, 0) + rate * dt * 1000
                f.write(f"cg /sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/"
                        f"cri-containerd-{cid(scen + pod + c)}.scope {usage[key]:.0f} {80 * 2**20} {10 * 2**20}\n")


def fortio_json(lat, qps, secs):
    n = int(qps * secs)
    pct = [{"Percentile": p, "Value": lat * m / 1000} for p, m in ((50, 1), (90, 1.6), (95, 2), (99, 3.2), (99.9, 5))]
    return {"DurationHistogram": {"Count": n, "Avg": lat * 1.1 / 1000, "Max": lat * 8 / 1000, "Percentiles": pct},
            "RetCodes": {"200": n - random.randint(0, 2)}, "ActualQPS": qps, "ActualDuration": secs * 1e9,
            "SocketCount": 8}


def iperf_json(gbps):
    return {"end": {"sum_received": {"bits_per_second": gbps * 1e9}, "sum_sent": {"bits_per_second": gbps * 1.01e9,
            "retransmits": random.randint(0, 40)}, "cpu_utilization_percent": {"host_total": 40, "remote_total": 35}}}


def record(*args):
    """bench/record.py with the arguments bench/run.sh passes"""
    sys.argv = ["record.py", *map(str, args)]
    recorder.main()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="results/bench-fake")
    ap.add_argument("--runs", type=int, default=2, help="runs appended to the CSVs (aggregate must pick the latest)")
    ap.add_argument("--repeats", type=int, default=3)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    tmp = tempfile.mkdtemp()
    t = time.time()
    for run in range(args.runs):
        run_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(t + run * 3600))
        bias = args.runs - run  # older runs are visibly off, so mixing them in would show
        for scen in SCENARIOS:
            lf, tf, extra = COST[scen]
            podlist, containers = pods(scen)
            with open(f"{tmp}/pods.json", "w") as f:
                json.dump(podlist, f)
            usage = {}

            def measured(suite, path, rep, qps, payload, raw, load_mc, secs):
                nonlocal t
                ctx = ["--run-id", run_id, "--scenario", scen, "--suite", suite, "--path", path, "--repeat", rep,
                       "--qps-target", qps, "--payload-bytes", payload, "--connections", 8]
                snapshot(f"{tmp}/before", scen, containers, t, usage, 0, 5)
                t += secs
                snapshot(f"{tmp}/after", scen, containers, t, usage, load_mc, secs)
                if raw is not None:
                    with open(f"{tmp}/raw.json", "w") as f:
                        json.dump(raw, f)
                    kind, out = ("iperf3", "throughput") if suite in ("iperf3", "link") else ("fortio", "latency")
                    record(kind, "--out", f"{args.out}/{out}.csv", *ctx, f"{tmp}/raw.json")
                record("resources", "--out", f"{args.out}/resources.csv", *ctx, f"{tmp}/before", f"{tmp}/after",
                       f"{tmp}/pods.json")

            for rep in range(1, args.repeats + 1):
                j = random.uniform(0.95, 1.05) / bias
                measured("idle", "none", rep, 0, 0, None, 0, 30)
                for path, base in (("same", 9.0), ("cross", 6.0)):
                    gb = base * tf * j
                    measured("iperf3", path, rep, 0, 0, iperf_json(gb), 400 + extra + 50 * gb, 30)
                for path, base, q in (("same", 0.4, 1000), ("cross", 0.6, 1000), ("app", 9.0, 50)):
                    measured("latency", path, rep, q, 0, fortio_json(base * lf / j, q, 60), 150 + extra * q / 1000, 60)
                for path, base in (("same", 0.4), ("cross", 0.6)):
                    for size in (64, 1024, 1400, 4096, 65536):
                        mtu = 1.3 if scen == "S2a" and size > 1400 and path == "cross" else 1
                        lat = base * lf * (1 + size / 16384) * mtu / j
                        measured("payload", path, rep, 500, size, fortio_json(lat, 500, 20), 100 + extra / 2, 20)
                for path, base, sat, steps in (("same", 0.4, 6000, (100, 1000, 4000, 8000, 0)),
                                               ("cross", 0.6, 5000, (100, 1000, 4000, 8000, 0)),
                                               ("app", 9.0, 300, (10, 50, 200, 400, 0))):
                    cap = sat / lf * j
                    for q in steps:
                        got = min(q or 1e9, cap)
                        lat = base * lf * (1 + 3 * (got / cap) ** 4) / j
                        measured("qps", path, rep, q, 0, fortio_json(lat, got, 20), 100 + extra * got / 1000, 20)
        for rep in range(1, args.repeats + 1):
            # link is its own run in practice (make bench-link)
            measured_link_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(t + run * 3600 + 1800))
            with open(f"{tmp}/raw.json", "w") as f:
                json.dump(iperf_json(10.5 / bias), f)
            record("iperf3", "--out", f"{args.out}/throughput.csv", "--run-id", measured_link_id, "--scenario", "S0",
                   "--suite", "link", "--path", "node", "--repeat", rep, "--qps-target", 0, "--payload-bytes", 0,
                   "--connections", 8, f"{tmp}/raw.json")
    print(f"fake results in {args.out}")


if __name__ == "__main__":
    main()
