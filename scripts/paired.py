#!/usr/bin/env python3
"""Per-round latency differences between configuration pairs (report table of per-control overhead).

A difference counts only when it has the same sign in every round; the reported value is the
median of the per-round differences.
"""
import argparse
import collections
import csv
import statistics
from pathlib import Path

# (parent, child): the control that child adds
PAIRS = [("S0", "S1"), ("S1", "S2a"), ("S1", "S2b-plain"), ("S2b-plain", "S2b"), ("S2a", "S2b"), ("S2b", "S3")]
METRICS = ("p50_ms", "p99_ms")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="indir", default="results/bench")
    ap.add_argument("--run-id", required=True, help="run that holds all configurations of the latency suite")
    a = ap.parse_args()

    vals = collections.defaultdict(dict)
    with open(Path(a.indir) / "latency.csv") as f:
        for r in csv.DictReader(f):
            if r["run_id"] == a.run_id and r["suite"] == "latency" and r["component"] == "client" and r["metric"] in METRICS:
                vals[(r["path"], r["metric"])][(r["scenario"], int(r["repeat"]))] = float(r["value"])

    out = Path(a.indir) / "deltas.csv"
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["path", "metric", "parent", "child", "rounds", "median_diff_ms", "median_diff_pct", "same_sign_all_rounds"])
        for (path, metric), v in sorted(vals.items()):
            for p, c in PAIRS:
                rounds = sorted(i for s, i in v if s == c and (p, i) in v)
                if not rounds:
                    continue
                d = [v[(c, i)] - v[(p, i)] for i in rounds]
                rel = [100 * x / v[(p, i)] for x, i in zip(d, rounds)]
                same = all(x > 0 for x in d) or all(x < 0 for x in d)
                w.writerow([path, metric, p, c, len(rounds), f"{statistics.median(d):.4f}", f"{statistics.median(rel):.1f}", same])
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
