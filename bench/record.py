#!/usr/bin/env python3
"""Turns raw fortio/iperf3 JSON and node counter snapshots (bench/node-snapshot.sh) into tidy CSV rows (stdlib only).

record.py fortio    --out F <ctx> RAW.json
record.py iperf3    --out F <ctx> RAW.json
record.py resources --out F <ctx> BEFORE AFTER PODS.json
record.py top       --out F <ctx> TOPFILE
record.py versions  --out F --run-id ID < "key<TAB>value" lines
"""
import argparse
import csv
import json
import os
import re
import sys
from datetime import datetime, timezone

COLUMNS = ["time", "run_id", "scenario", "suite", "path", "repeat", "qps_target",
           "payload_bytes", "connections", "component", "object", "metric", "value", "unit"]
CTX = ["run_id", "scenario", "suite", "path", "repeat", "qps_target", "payload_bytes", "connections"]

# containers outside these are ignored; kube-system only for the Cilium agent/operator/envoy
KEEP_NS = {"bookinfo", "istio-system"}
BENCH_PREFIXES = ("bench-client-", "fortio-", "iperf3-", "link-")


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def writer(path, columns):
    new = not os.path.exists(path) or os.path.getsize(path) == 0
    f = open(path, "a", newline="")
    w = csv.writer(f)
    if new:
        w.writerow(columns)
    return f, w


def emit(args, rows):
    f, w = writer(args.out, COLUMNS)
    t = args.time or now()
    ctx = [getattr(args, c) for c in CTX]
    for component, obj, metric, value, unit in rows:
        if value is None:
            continue
        w.writerow([t, *ctx, component, obj, metric, f"{value:.6g}", unit])
    f.close()


def load_json(path):
    # tolerate log lines before the JSON document
    with open(path) as f:
        text = f.read()
    return json.JSONDecoder().raw_decode(text[text.index("{"):])[0]


def fortio(args):
    r = load_json(args.files[0])
    h = r["DurationHistogram"]
    pct = {p["Percentile"]: p["Value"] * 1000 for p in h.get("Percentiles") or []}
    total = h["Count"]
    ok = sum(n for code, n in (r.get("RetCodes") or {}).items() if str(code) in ("200", "SERVING"))
    errors = total - ok
    rows = [("client", "", f"p{p:g}_ms".replace(".", ""), v, "ms") for p, v in sorted(pct.items())]
    rows += [
        ("client", "", "avg_ms", h["Avg"] * 1000, "ms"),
        ("client", "", "max_ms", h["Max"] * 1000, "ms"),
        ("client", "", "qps_actual", r["ActualQPS"], "req/s"),
        ("client", "", "requests", total, "count"),
        ("client", "", "errors", errors, "count"),
        ("client", "", "error_pct", 100.0 * errors / total if total else None, "%"),
        ("client", "", "duration_s", r["ActualDuration"] / 1e9, "s"),
        ("client", "", "sockets", r.get("SocketCount"), "count"),
    ]
    emit(args, rows)


def iperf3(args):
    r = load_json(args.files[0])
    if "error" in r:
        sys.exit(f"iperf3 error: {r['error']}")
    end = r["end"]
    cpu = end.get("cpu_utilization_percent", {})
    rows = [
        ("client", "", "gbps", end["sum_received"]["bits_per_second"] / 1e9, "Gbit/s"),
        ("client", "", "sent_gbps", end["sum_sent"]["bits_per_second"] / 1e9, "Gbit/s"),
        ("client", "", "retransmits", end["sum_sent"].get("retransmits"), "count"),
        ("client", "", "cpu_client_pct", cpu.get("host_total"), "%"),
        ("client", "", "cpu_server_pct", cpu.get("remote_total"), "%"),
    ]
    emit(args, rows)


CONTAINER_ID = re.compile(r"[0-9a-f]{64}")


def component(ns, pod, container):
    if container == "istio-proxy":
        return "proxy"
    if ns == "kube-system":
        return "cilium"
    if ns == "istio-system":
        return "istiod"
    return "bench" if pod.startswith(BENCH_PREFIXES) else "app"


def pod_map(path):
    """container ID -> (namespace, pod, container) from `kubectl get pods -A -o json`"""
    with open(path) as f:
        pods = json.load(f)["items"]
    out = {}
    for p in pods:
        ns, name = p["metadata"]["namespace"], p["metadata"]["name"]
        st = p.get("status", {})
        for c in (st.get("containerStatuses") or []) + (st.get("initContainerStatuses") or []):
            cid = (c.get("containerID") or "").rpartition("://")[2]
            if cid:
                out[cid] = (ns, name, c["name"])
    return out


def keep(ns, pod):
    # kube-system only for the Cilium agent/operator/envoy
    return ns in KEEP_NS or (ns == "kube-system" and pod.startswith("cilium"))


def parse_snapshot(path, ids):
    """bench/node-snapshot.sh output of every node, separated by '# zt-node <name>' lines;
    returns {node: {"ts", "hz", "cpu", "mem", "cg": {(component, object): (usage_usec, working_set)}}}"""
    out, n = {}, None
    with open(path) as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            if p[0] == "#" and p[1:2] == ["zt-node"]:
                n = out.setdefault(p[2], {"cg": {}})
                node = p[2]
            elif n is None:
                continue
            elif p[0] in ("ts", "hz", "cpu", "mem"):
                n[p[0]] = float(p[1])
            elif p[0] == "cg" and len(p) == 5:
                # systemd driver: .../cri-containerd-<id>.scope, cgroupfs: .../pod<uid>/<id>; pod and QoS levels have none
                m = CONTAINER_ID.findall(p[1])
                if not m or m[-1] not in ids:
                    continue
                ns, pod, c = ids[m[-1]]
                if not keep(ns, pod):
                    continue
                usage, current, inactive = (int(x) for x in p[2:])
                n["cg"][(component(ns, pod, c), f"{node}/{ns}/{pod}/{c}")] = (usage, max(current - inactive, 0))
    return out


def resources(args):
    """CPU over the window between the two snapshots, per node with the node's own timestamps"""
    ids = pod_map(args.files[2])
    before, after = parse_snapshot(args.files[0], ids), parse_snapshot(args.files[1], ids)
    rows = []
    for node, a in sorted(after.items()):
        b = before.get(node)
        if not b or "ts" not in a or "ts" not in b:
            continue
        dt = a["ts"] - b["ts"]
        if dt <= 0:
            continue
        rows.append(("node", f"node/{node}", "cpu_mcores", (a["cpu"] - b["cpu"]) / a["hz"] / dt * 1000, "mcores"))
        rows.append(("node", f"node/{node}", "mem_mib", a["mem"] / 2**20, "MiB"))
        for key, (u2, ws) in sorted(a["cg"].items()):
            comp, obj = key
            rows.append((comp, obj, "mem_mib", ws / 2**20, "MiB"))
            # a container that started inside the window has no before value
            if key in b["cg"] and u2 >= b["cg"][key][0]:
                rows.append((comp, obj, "cpu_mcores", (u2 - b["cg"][key][0]) / 1e3 / dt, "mcores"))
        rows.append(("node", f"node/{node}", "window_s", dt, "s"))
    emit(args, rows)


def qty_cpu(s):
    return float(s[:-1]) if s.endswith("m") else float(s) * 1000


def qty_mem(s):
    units = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024}
    for u, mul in units.items():
        if s.endswith(u):
            return float(s[:-2]) * mul
    return float(s) / 2**20


def top(args):
    """blocks from bench/run.sh: '# top <nodes|pods> <ns>' then `kubectl top --no-headers` output"""
    rows, kind, ns = [], None, None
    with open(args.files[0]) as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            if p[0] == "#":
                kind, ns = p[2], (p[3] if len(p) > 3 else None)
                continue
            try:
                if kind == "nodes":
                    rows.append(("node", f"node/{p[0]}", "top_cpu_mcores", qty_cpu(p[1]), "mcores"))
                    rows.append(("node", f"node/{p[0]}", "top_mem_mib", qty_mem(p[3]), "MiB"))
                elif kind == "pods":
                    pod, c = p[0], p[1]
                    if not keep(ns, pod):
                        continue
                    comp = component(ns, pod, c)
                    rows.append((comp, f"{ns}/{pod}/{c}", "top_cpu_mcores", qty_cpu(p[2]), "mcores"))
                    rows.append((comp, f"{ns}/{pod}/{c}", "top_mem_mib", qty_mem(p[3]), "MiB"))
            except (IndexError, ValueError):
                continue
    emit(args, rows)


def versions(args):
    f, w = writer(args.out, ["time", "run_id", "item", "version"])
    t = now()
    for line in sys.stdin:
        if "\t" in line:
            k, v = line.rstrip("\n").split("\t", 1)
            w.writerow([t, args.run_id, k, v])
    f.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["fortio", "iperf3", "resources", "top", "versions"])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--out", required=True)
    ap.add_argument("--time")
    for c in CTX:
        ap.add_argument("--" + c.replace("_", "-"), dest=c, default="")
    args = ap.parse_args()
    {"fortio": fortio, "iperf3": iperf3, "resources": resources, "top": top, "versions": versions}[args.cmd](args)


if __name__ == "__main__":
    main()
