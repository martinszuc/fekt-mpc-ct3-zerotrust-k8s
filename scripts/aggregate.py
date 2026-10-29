#!/usr/bin/env python3
"""Aggregates results/bench/*.csv across repeats (stdlib only).

The CSVs are append-only; only the selected runs are used: --run-id a,b, or by default the latest run
plus the latest node-to-node link run (make bench-link is a run of its own).

Writes summary.csv (median, IQR, min/max per scenario, suite, path, load and metric),
cost.csv (CPU cost per 1000 requests and per Gbit/s, one value per run) and knee.csv (saturation per scenario and path).
"""
import argparse
import csv
import os
import statistics
from collections import defaultdict

SCENARIOS = ["S0", "S1", "S2a", "S2b-plain", "S2b", "S3"]
PATHS = ["same", "cross", "app", "node"]
KNEE_TOLERANCE = 0.95   # a target rate counts as sustained if at least 95 % of it was achieved


def scenario_key(s):
    return SCENARIOS.index(s) if s in SCENARIOS else len(SCENARIOS)


def read(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["value"] = float(r["value"])
        r["qps_target"] = int(float(r["qps_target"] or 0))
        r["payload_bytes"] = int(float(r["payload_bytes"] or 0))
    return rows


def stats(values):
    v = sorted(values)
    if len(v) >= 2:
        q1, _, q3 = statistics.quantiles(v, n=4, method="inclusive")
    else:
        q1 = q3 = v[0]
    return {"n": len(v), "median": statistics.median(v), "q1": q1, "q3": q3, "min": v[0], "max": v[-1]}


def run_key(r):
    return (r["run_id"], r["scenario"], r["suite"], r["path"], r["repeat"], r["qps_target"], r["payload_bytes"])


def summarize(rows):
    groups = defaultdict(list)
    for r in rows:
        groups[(r["scenario"], r["suite"], r["path"], r["qps_target"], r["payload_bytes"], r["metric"])].append(r["value"])
    out = []
    for (s, suite, path, q, p, m), vals in groups.items():
        out.append({"scenario": s, "suite": suite, "path": path, "qps_target": q, "payload_bytes": p,
                    "metric": m, **stats(vals)})
    out.sort(key=lambda r: (r["suite"], scenario_key(r["scenario"]), r["path"], r["qps_target"],
                            r["payload_bytes"], r["metric"]))
    return out


def per_run_cpu(resources):
    """CPU (mcores) per run, by scope; node CPU summed over all nodes"""
    out = defaultdict(lambda: defaultdict(float))
    for r in resources:
        if r["metric"] != "cpu_mcores":
            continue
        k = run_key(r)
        c = r["component"]
        if c == "node":
            out[k]["node"] += r["value"]
        else:
            out[k][c] += r["value"]
            if c in ("bench", "app", "proxy"):
                out[k]["pods"] += r["value"]
    return out


def cost(latency, throughput, resources):
    """one row per run: CPU per unit of work; node CPU net of the scenario's idle baseline;
    no row for a component the configuration does not run (proxy without the mesh)"""
    cpu = per_run_cpu(resources)
    idle = defaultdict(list)
    for k, v in cpu.items():
        if k[2] == "idle":
            idle[k[1]].append(v["node"])
    idle_node = {s: statistics.median(v) for s, v in idle.items()}

    work = {}
    for r in latency:
        if r["metric"] == "qps_actual":
            work[run_key(r)] = ("krps", r["value"] / 1000)
    for r in throughput:
        if r["metric"] == "gbps":
            work[run_key(r)] = ("gbps", r["value"])

    rows = []
    for k, (unit, amount) in work.items():
        if k not in cpu or amount <= 0:
            continue
        c = cpu[k]
        scopes = {"node_net": c["node"] - idle_node[k[1]] if k[1] in idle_node else None,
                  "node": c["node"], "pods": c.get("pods"), "proxy": c.get("proxy"), "cilium": c.get("cilium")}
        for scope, mc in scopes.items():
            if mc is None:
                continue
            rows.append({"run_id": k[0], "scenario": k[1], "suite": k[2], "path": k[3], "repeat": k[4],
                         "qps_target": k[5], "payload_bytes": k[6], "scope": scope,
                         "metric": f"mcores_per_{unit}_{scope}", "value": mc / amount})
    return rows


def knee(latency):
    """per scenario and path: highest sustained target rate and the maximum achieved rate"""
    achieved = defaultdict(lambda: defaultdict(list))
    for r in latency:
        if r["suite"] == "qps" and r["metric"] == "qps_actual":
            achieved[(r["scenario"], r["path"])][r["qps_target"]].append(r["value"])
    out = []
    for (s, path), by_q in achieved.items():
        med = {q: statistics.median(v) for q, v in by_q.items()}
        sustained = [q for q, a in med.items() if q > 0 and a >= KNEE_TOLERANCE * q]
        out.append({"scenario": s, "path": path, "knee_qps": max(sustained) if sustained else 0,
                    "max_qps": max(med.values())})
    # calibration: 50 % of the lowest saturation (heaviest scenario) per path
    for path in {r["path"] for r in out}:
        lowest = min(r["max_qps"] for r in out if r["path"] == path)
        for r in out:
            if r["path"] == path:
                r["recommended_qps"] = round(lowest * 0.5)
    out.sort(key=lambda r: (PATHS.index(r["path"]) if r["path"] in PATHS else 9, scenario_key(r["scenario"])))
    return out


def write(path, rows, fields):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: (f"{v:.6g}" if isinstance(v, float) else v) for k, v in r.items()})


def select_runs(rows, run_ids=None):
    """run_ids given: exactly those; otherwise the latest link run and the latest run of everything else"""
    if not run_ids:
        latest = {}
        for r in rows:
            family = "link" if r["suite"] == "link" else "main"
            latest[family] = max(latest.get(family, ""), r["run_id"])
        run_ids = set(latest.values())
    return set(run_ids)


def load(indir, run_ids=None):
    """latency, throughput and resource rows of the selected runs"""
    tables = [read(os.path.join(indir, f)) for f in ("latency.csv", "throughput.csv", "resources.csv")]
    keep = select_runs([r for t in tables for r in t], run_ids)
    missing = set(run_ids or ()) - {r["run_id"] for t in tables for r in t}
    if missing:
        raise SystemExit(f"run ids not found in {indir}: {', '.join(sorted(missing))}")
    if keep:
        print(f"runs: {', '.join(sorted(keep))}")
    return tuple([r for r in t if r["run_id"] in keep] for t in tables)


def run_ids_arg(v):
    return [x for x in v.split(",") if x]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="indir", default="results/bench")
    ap.add_argument("--run-id", type=run_ids_arg, help="comma-separated run ids (default: latest)")
    args = ap.parse_args()
    latency, throughput, resources = load(args.indir, args.run_id)
    if not latency and not throughput:
        raise SystemExit(f"no results in {args.indir}; run make bench first")

    summary = summarize(latency + throughput)
    costs = cost(latency, throughput, resources)
    summary += summarize(costs)
    write(os.path.join(args.indir, "summary.csv"), summary,
          ["scenario", "suite", "path", "qps_target", "payload_bytes", "metric", "n", "median", "q1", "q3", "min", "max"])
    write(os.path.join(args.indir, "cost.csv"), costs,
          ["run_id", "scenario", "suite", "path", "repeat", "qps_target", "payload_bytes", "scope", "metric", "value"])
    knees = knee(latency)
    write(os.path.join(args.indir, "knee.csv"), knees,
          ["scenario", "path", "knee_qps", "max_qps", "recommended_qps"])
    for r in knees:
        print(f"{r['path']:6} {r['scenario']:10} knee {r['knee_qps']:>7} max {r['max_qps']:>9.0f} "
              f"-> fixed QPS {r['recommended_qps']}")


if __name__ == "__main__":
    main()
