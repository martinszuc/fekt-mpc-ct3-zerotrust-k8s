#!/usr/bin/env python3
"""Figures for the report from results/bench/*.csv -> <out>/*.pdf|png, in the shared style (scripts/style.py).

Bars: median across repeats, whisker min to max, dots for single repeats.
Curves: median, band IQR. Same configuration order, label, color and marker in every figure.
"""
import argparse
import statistics
from collections import defaultdict

import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, LogLocator

from aggregate import cost, knee, load, run_ids_arg, scenario_key, stats
from style import INK, MARKER, MUTED, color, label, panel, save

PATH_LABEL = {"same": "same node", "cross": "cross node", "app": "full app", "node": "node to node"}
WG_MTU = 1405


def present(rows):
    return sorted({r["scenario"] for r in rows}, key=scenario_key)


def values(rows, **match):
    """per (scenario) list of values for rows matching all fields"""
    out = defaultdict(list)
    for r in rows:
        if all(r[k] == v for k, v in match.items()):
            out[r["scenario"]].append(r["value"])
    return out


def bars(ax, by_scenario, scenarios, ylabel):
    xs = range(len(scenarios))
    for x, s in zip(xs, scenarios):
        v = by_scenario.get(s)
        if not v:
            continue
        st = stats(v)
        ax.bar(x, st["median"], width=0.7, color=color(s), edgecolor="white", linewidth=1)
        ax.errorbar(x, st["median"], yerr=[[st["median"] - st["min"]], [st["max"] - st["median"]]],
                    fmt="none", ecolor=INK, elinewidth=0.8, capsize=2)
        ax.scatter([x] * len(v), v, s=6, color=INK, alpha=0.5, zorder=3, linewidths=0)
    ax.set_xticks(list(xs), [label(s) for s in scenarios], rotation=30, ha="right")
    ax.set_ylabel(ylabel)
    ax.grid(axis="x", visible=False)
    ax.set_ylim(bottom=0)


def curve(ax, points, s):
    """points: {x: [y...]} -> median line with IQR band"""
    xs = sorted(points)
    st = [stats(points[x]) for x in xs]
    ax.fill_between(xs, [p["q1"] for p in st], [p["q3"] for p in st], color=color(s), alpha=0.15, lw=0)
    ax.plot(xs, [p["median"] for p in st], color=color(s), marker=MARKER.get(s, "o"), label=label(s))


def plain_log(ax, axis):
    """log scale with 1-2-5 ticks printed as plain numbers"""
    a = getattr(ax, f"{axis}axis")
    a.set_major_locator(LogLocator(base=10, subs=(1, 2, 5)))
    a.set_minor_formatter(FuncFormatter(lambda v, _: ""))
    a.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))


def size_label(v, _):
    return f"{v / 1024:g} Ki" if v >= 1024 else f"{v:g}"


def legend(fig, scenarios):
    handles = [plt.Line2D([], [], color=color(s), marker=MARKER.get(s, "o"), label=label(s)) for s in scenarios]
    fig.legend(handles=handles, loc="upper center", ncol=min(len(scenarios), 3), bbox_to_anchor=(0.5, 1.04))


def fig_latency(latency, outdir):
    rows = [r for r in latency if r["suite"] == "latency"]
    if not rows:
        return
    scen = present(rows)
    paths = [p for p in ("same", "cross", "app") if any(r["path"] == p for r in rows)]
    pcts = ["p50_ms", "p95_ms", "p99_ms"]
    fig, axes = plt.subplots(len(paths), len(pcts), figsize=(7, 1.9 * len(paths)), squeeze=False)
    for i, path in enumerate(paths):
        for j, m in enumerate(pcts):
            ax = axes[i][j]
            bars(ax, values(rows, path=path, metric=m), scen, "ms" if j == 0 else "")
            panel(ax, i * len(pcts) + j, f"{m[:-3]}, {PATH_LABEL[path]}")
    fig.tight_layout()
    save(fig, outdir, "latency")


def fig_throughput(throughput, outdir):
    rows = [r for r in throughput if r["suite"] == "iperf3"]
    if not rows:
        return
    scen = present(rows)
    link = [r["value"] for r in throughput if r["suite"] == "link" and r["metric"] == "gbps"]
    fig, axes = plt.subplots(2, 2, figsize=(6, 3.8), squeeze=False)
    for j, path in enumerate(("same", "cross")):
        bars(axes[0][j], values(rows, path=path, metric="gbps"), scen, "Gbit/s" if j == 0 else "")
        panel(axes[0][j], j, f"throughput, {PATH_LABEL[path]}")
        if link and path == "cross":
            m = statistics.median(link)
            axes[0][j].axhline(m, color=MUTED, ls="--", lw=1)
            axes[0][j].set_ylim(0, max(axes[0][j].get_ylim()[1], m * 1.12))
            axes[0][j].annotate(f"node link {m:.1f}", (len(scen) - 0.5, m), ha="right", va="bottom", color=MUTED,
                                fontsize=7)
        bars(axes[1][j], values(rows, path=path, metric="retransmits"), scen, "retransmits" if j == 0 else "")
        panel(axes[1][j], 2 + j, f"TCP retransmits, {PATH_LABEL[path]}")
    fig.tight_layout()
    save(fig, outdir, "throughput")


def fig_qps(latency, outdir):
    rows = [r for r in latency if r["suite"] == "qps"]
    if not rows:
        return
    scen = present(rows)
    paths = [p for p in ("same", "cross", "app") if any(r["path"] == p for r in rows)]
    # x is the achieved rate (median per target), so the "as fast as possible" step lands at saturation
    achieved = defaultdict(list)
    for r in rows:
        if r["metric"] == "qps_actual":
            achieved[(r["scenario"], r["path"], r["qps_target"])].append(r["value"])
    fig, axes = plt.subplots(2, len(paths), figsize=(2.6 * len(paths), 4), squeeze=False)
    for j, path in enumerate(paths):
        for i, m in enumerate(("p50_ms", "p99_ms")):
            ax = axes[i][j]
            for s in scen:
                pts = defaultdict(list)
                for r in rows:
                    if r["scenario"] == s and r["path"] == path and r["metric"] == m:
                        pts[statistics.median(achieved[(s, path, r["qps_target"])])].append(r["value"])
                if pts:
                    curve(ax, pts, s)
            ax.set_xscale("log")
            ax.set_yscale("log")
            plain_log(ax, "x")
            plain_log(ax, "y")
            panel(ax, i * len(paths) + j, f"{m[:-3]}, {PATH_LABEL[path]}")
            ax.set_xlabel("achieved req/s" if i == 1 else "")
            ax.set_ylabel("ms" if j == 0 else "")
    legend(fig, scen)
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    save(fig, outdir, "qps-sweep")


def fig_payload(latency, outdir):
    rows = [r for r in latency if r["suite"] == "payload"]
    if not rows:
        return
    scen = present(rows)
    fig, axes = plt.subplots(2, 2, figsize=(6, 4), squeeze=False)
    for j, path in enumerate(("same", "cross")):
        for i, m in enumerate(("p50_ms", "p99_ms")):
            ax = axes[i][j]
            for s in scen:
                pts = defaultdict(list)
                for r in rows:
                    if r["scenario"] == s and r["path"] == path and r["metric"] == m:
                        pts[r["payload_bytes"]].append(r["value"])
                if pts:
                    curve(ax, pts, s)
            ax.set_xscale("log", base=2)
            ax.xaxis.set_major_locator(LogLocator(base=4))
            ax.xaxis.set_major_formatter(FuncFormatter(size_label))
            ax.xaxis.set_minor_formatter(FuncFormatter(lambda v, _: ""))
            ax.axvline(WG_MTU, color=MUTED, ls=":", lw=1)
            if i == 0:
                ax.annotate("WireGuard MTU", (WG_MTU, 1), xycoords=("data", "axes fraction"), ha="right",
                            va="top", rotation=90, color=MUTED, fontsize=6)
            panel(ax, i * 2 + j, f"{m[:-3]}, {PATH_LABEL[path]}")
            ax.set_xlabel("payload (bytes, request and response)" if i == 1 else "")
            ax.set_ylabel("ms" if j == 0 else "")
            ax.set_ylim(bottom=0)
    legend(fig, scen)
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    save(fig, outdir, "payload-sweep")


def fig_cost(costs, outdir):
    rows = [r for r in costs if r["suite"] == "latency"]
    if rows:
        scen = present(rows)
        paths = [p for p in ("same", "cross", "app") if any(r["path"] == p for r in rows)]
        scopes = [("node_net", "node CPU above idle"), ("proxy", "istio-proxy CPU")]
        fig, axes = plt.subplots(len(scopes), len(paths), figsize=(2.4 * len(paths), 3.8), squeeze=False)
        for i, (scope, title) in enumerate(scopes):
            for j, path in enumerate(paths):
                bars(axes[i][j], values(rows, path=path, metric=f"mcores_per_krps_{scope}"), scen,
                     "mcores per 1000 req/s" if j == 0 else "")
                panel(axes[i][j], i * len(paths) + j, f"{title}, {PATH_LABEL[path]}")
        fig.tight_layout()
        save(fig, outdir, "cost-per-request")
    rows = [r for r in costs if r["suite"] == "iperf3"]
    if rows:
        scen = present(rows)
        fig, axes = plt.subplots(1, 2, figsize=(6, 2), squeeze=False)
        for j, path in enumerate(("same", "cross")):
            bars(axes[0][j], values(rows, path=path, metric="mcores_per_gbps_node_net"), scen,
                 "mcores per Gbit/s" if j == 0 else "")
            panel(axes[0][j], j, f"node CPU above idle, {PATH_LABEL[path]}")
        fig.tight_layout()
        save(fig, outdir, "cost-per-gbit")


def fig_resources(resources, outdir):
    # memory at the end of each latency run, summed per component
    per_run = defaultdict(lambda: defaultdict(float))
    for r in resources:
        if r["suite"] == "latency" and r["metric"] == "mem_mib" and r["component"] in ("proxy", "cilium"):
            per_run[(r["run_id"], r["scenario"], r["path"], r["repeat"], r["component"])][r["object"]] = r["value"]
    if not per_run:
        return
    rows = [{"scenario": k[1], "component": k[4], "value": sum(v.values())} for k, v in per_run.items()]
    scen = present(rows)
    fig, axes = plt.subplots(1, 2, figsize=(6, 2), squeeze=False)
    for j, (comp, title) in enumerate((("proxy", "istio-proxy memory, all sidecars"),
                                       ("cilium", "Cilium memory, all nodes"))):
        bars(axes[0][j], values(rows, component=comp), scen, "MiB" if j == 0 else "")
        panel(axes[0][j], j, title)
    fig.tight_layout()
    save(fig, outdir, "memory")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="indir", default="results/bench")
    ap.add_argument("--out", default="docs/figures/bench")
    ap.add_argument("--run-id", type=run_ids_arg, help="comma-separated run ids (default: latest)")
    args = ap.parse_args()
    latency, throughput, resources = load(args.indir, args.run_id)
    if not latency and not throughput:
        raise SystemExit(f"no results in {args.indir}; run make bench first")
    costs = cost(latency, throughput, resources)
    fig_latency(latency, args.out)
    fig_throughput(throughput, args.out)
    fig_qps(latency, args.out)
    fig_payload(latency, args.out)
    fig_cost(costs, args.out)
    fig_resources(resources, args.out)
    for r in knee(latency):
        print(f"knee {r['path']:6} {r['scenario']:10} sustained {r['knee_qps']} max {r['max_qps']:.0f}")


if __name__ == "__main__":
    main()
