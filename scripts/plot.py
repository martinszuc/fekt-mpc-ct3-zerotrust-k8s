#!/usr/bin/env python3
"""Figures for the report from results/bench/*.csv -> <out>/*.pdf|png, in the shared style (scripts/style.py).

Bars: median across repeats, whisker min to max, dots for single repeats.
Curves: median, band min to max (sweeps have 2 repeats per step). Same configuration order, label, color and marker in every figure.
"""
import argparse
import statistics
from collections import defaultdict

import matplotlib.pyplot as plt
import math

from matplotlib.patches import Patch
from matplotlib.ticker import FuncFormatter, Locator, LogLocator, MaxNLocator

from aggregate import cost, drop_arg, knee, load, run_ids_arg, scenario_key, stats
from style import FIGW, HATCH, INK, MARKER, MUTED, color, comma, label, num, panel, save

PATH_LABEL = {"same": "na jednom uzle", "cross": "medzi uzlami", "app": "cez aplikáciu", "node": "uzol–uzol"}
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
        ax.bar(x, st["median"], width=0.7, color=color(s), edgecolor="white", linewidth=1, hatch=HATCH.get(s))
        ax.errorbar(x, st["median"], yerr=[[st["median"] - st["min"]], [st["max"] - st["median"]]],
                    fmt="none", ecolor=INK, elinewidth=0.8, capsize=2)
        ax.scatter([x] * len(v), v, s=6, color=INK, alpha=0.5, zorder=3, linewidths=0)
    ax.set_xticks(list(xs), [label(s) for s in scenarios], rotation=30, ha="right")
    ax.set_ylabel(ylabel)
    ax.grid(axis="x", visible=False)
    ax.set_ylim(bottom=0)
    comma(ax)


def curve(ax, points, s, gap=None):
    """points: {x: [y...]} -> median line with a min-max band; a last step more than `gap` times
    the previous x is drawn dashed (range between the two points not measured)"""
    xs = sorted(points)
    st = [stats(points[x]) for x in xs]
    med = [p["median"] for p in st]
    ax.fill_between(xs, [min(points[x]) for x in xs], [max(points[x]) for x in xs], color=color(s), alpha=0.15, lw=0)
    n = len(xs) - 1 if gap and len(xs) > 2 and xs[-1] > gap * xs[-2] else len(xs)
    ax.plot(xs[:n], med[:n], color=color(s), marker=MARKER.get(s, "o"), label=label(s))
    if n < len(xs):
        ax.plot(xs[-2:], med[-2:], color=color(s), ls="--", lw=1)
        ax.plot(xs[-1:], med[-1:], color=color(s), marker=MARKER.get(s, "o"), ls="none")


class Log125(Locator):
    """1-2-5 ticks on a log axis; under 3 of them in view -> 4 evenly spaced ticks"""
    def __call__(self):
        lo, hi = sorted(self.axis.get_view_interval())
        lo = max(lo, 1e-9)
        t = [m * 10 ** k for k in range(math.floor(math.log10(lo)), math.ceil(math.log10(hi)) + 1)
             for m in (1, 2, 5) if lo <= m * 10 ** k <= hi]
        return t if len(t) >= 3 else MaxNLocator(4).tick_values(lo, hi)


def plain_log(ax, axis):
    """log scale with 1-2-5 ticks printed as plain numbers"""
    a = getattr(ax, f"{axis}axis")
    a.set_major_locator(Log125())
    a.set_minor_formatter(FuncFormatter(lambda v, _: ""))
    a.set_major_formatter(FuncFormatter(num))


def rate_log(ax):
    """log x axis of request rates: decades only, '100', '1 tis.', '10 tis.'"""
    ax.xaxis.set_major_locator(LogLocator(base=10, subs=(1,)))
    ax.xaxis.set_minor_formatter(FuncFormatter(lambda v, _: ""))
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v / 1000:g} tis." if v >= 1000 else f"{v:g}"))


def size_label(v, _):
    return f"{v / 1024:g} KiB" if v >= 1024 else f"{v:g}"


def legend(fig, scenarios, extra=()):
    handles = [plt.Line2D([], [], color=color(s), marker=MARKER.get(s, "o"), label=label(s)) for s in scenarios]
    fig.legend(handles=handles + list(extra), loc="outside upper center", ncol=3)


def bar_legend(fig, axes, scenarios):
    """3-column bar grids: one color legend instead of rotated x labels under every panel"""
    for row in axes:
        for ax in row:
            ax.tick_params(axis="x", bottom=False, labelbottom=False)
    fig.legend(handles=[Patch(facecolor=color(s), edgecolor="white", hatch=HATCH.get(s), label=label(s))
                        for s in scenarios], loc="outside upper center", ncol=3)


def bottom_labels_only(axes):
    for row in axes[:-1]:
        for ax in row:
            ax.tick_params(labelbottom=False)


def fig_latency(latency, outdir):
    rows = [r for r in latency if r["suite"] == "latency"]
    if not rows:
        return
    scen = present(rows)
    paths = [p for p in ("same", "cross", "app") if any(r["path"] == p for r in rows)]
    pcts = ["p50_ms", "p95_ms", "p99_ms"]
    fig, axes = plt.subplots(len(paths), len(pcts), figsize=(FIGW, 1.6 * len(paths) + 0.4), squeeze=False)
    for i, path in enumerate(paths):
        for j, m in enumerate(pcts):
            ax = axes[i][j]
            bars(ax, values(rows, path=path, metric=m), scen, "ms" if j == 0 else "")
            panel(ax, i * len(pcts) + j, f"{m[:-3]}, {PATH_LABEL[path]}")
    bar_legend(fig, axes, scen)
    save(fig, outdir, "latency")


def fig_throughput(throughput, outdir):
    rows = [r for r in throughput if r["suite"] == "iperf3"]
    if not rows:
        return
    scen = present(rows)
    link = [r["value"] for r in throughput if r["suite"] == "link" and r["metric"] == "gbps"]
    fig, axes = plt.subplots(2, 2, figsize=(FIGW, 3.8), squeeze=False)
    for j, path in enumerate(("same", "cross")):
        bars(axes[0][j], values(rows, path=path, metric="gbps"), scen, "Gbit/s" if j == 0 else "")
        panel(axes[0][j], j, f"priepustnosť, {PATH_LABEL[path]}")
        if link and path == "cross":
            m = statistics.median(link)
            axes[0][j].axhline(m, color=MUTED, ls="--", lw=1)
            axes[0][j].set_ylim(0, max(axes[0][j].get_ylim()[1], m * 1.12))
            axes[0][j].annotate(f"linka medzi uzlami {num(round(m, 1))} Gbit/s", (len(scen) - 0.5, m), ha="right", va="bottom", color=MUTED,
                                fontsize=7)
        bars(axes[1][j], values(rows, path=path, metric="retransmits"), scen, "opakované prenosy" if j == 0 else "")
        panel(axes[1][j], 2 + j, f"opakované prenosy TCP, {PATH_LABEL[path]}")
    bottom_labels_only(axes)
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
    fig, axes = plt.subplots(2, len(paths), figsize=(FIGW, 4.2), squeeze=False)
    for j, path in enumerate(paths):
        for i, m in enumerate(("p50_ms", "p99_ms")):
            ax = axes[i][j]
            for s in scen:
                pts = defaultdict(list)
                for r in rows:
                    if r["scenario"] == s and r["path"] == path and r["metric"] == m:
                        pts[statistics.median(achieved[(s, path, r["qps_target"])])].append(r["value"])
                if pts:
                    curve(ax, pts, s, gap=5)
            ax.set_xscale("log")
            ax.set_yscale("log")
            rate_log(ax)
            plain_log(ax, "y")
            panel(ax, i * len(paths) + j, f"{m[:-3]}, {PATH_LABEL[path]}")
            ax.set_xlabel("dosiahnuté požiadavky/s" if i == 1 else "")
            ax.set_ylabel("ms" if j == 0 else "")
    legend(fig, scen)
    save(fig, outdir, "qps-sweep")


def fig_payload(latency, outdir):
    rows = [r for r in latency if r["suite"] == "payload"]
    if not rows:
        return
    scen = present(rows)
    fig, axes = plt.subplots(2, 2, figsize=(FIGW, 4.2), squeeze=False)
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
            panel(ax, i * 2 + j, f"{m[:-3]}, {PATH_LABEL[path]}")
            ax.set_xlabel("veľkosť požiadavky a odpovede (B)" if i == 1 else "")
            ax.set_ylabel("ms" if j == 0 else "")
            ax.set_ylim(bottom=0)
            comma(ax)
    legend(fig, scen, [plt.Line2D([], [], color=MUTED, ls=":", lw=1, label="MTU WireGuard")])
    save(fig, outdir, "payload-sweep")


def fig_cost(costs, outdir):
    rows = [r for r in costs if r["suite"] == "latency"]
    if rows:
        scen = present(rows)
        paths = [p for p in ("same", "cross", "app") if any(r["path"] == p for r in rows)]
        # the measured component goes into the y label, titles do not fit a third of the text width
        unit = "milijadrá (m) na 1000 pož./s"
        scopes = [("node_net", f"CPU uzlov nad nečinnosťou\n{unit}"), ("proxy", f"CPU istio-proxy\n{unit}")]
        fig, axes = plt.subplots(len(scopes), len(paths), figsize=(FIGW, 4), squeeze=False)
        for i, (scope, ylabel) in enumerate(scopes):
            for j, path in enumerate(paths):
                bars(axes[i][j], values(rows, path=path, metric=f"mcores_per_krps_{scope}"), scen,
                     ylabel if j == 0 else "")
                panel(axes[i][j], i * len(paths) + j, PATH_LABEL[path])
        bar_legend(fig, axes, scen)
        save(fig, outdir, "cost-per-request")
    rows = [r for r in costs if r["suite"] == "iperf3"]
    if rows:
        scen = present(rows)
        fig, axes = plt.subplots(1, 2, figsize=(FIGW, 2.4), squeeze=False)
        for j, path in enumerate(("same", "cross")):
            bars(axes[0][j], values(rows, path=path, metric="mcores_per_gbps_node_net"), scen,
                 "milijadrá (m) na 1 Gbit/s" if j == 0 else "")
            panel(axes[0][j], j, f"CPU uzlov nad nečinnosťou, {PATH_LABEL[path]}")
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
    fig, axes = plt.subplots(1, 2, figsize=(FIGW, 2.4), squeeze=False)
    for j, (comp, title) in enumerate((("proxy", "pamäť istio-proxy, všetky sidecary"),
                                       ("cilium", "pamäť Cilium, všetky uzly"))):
        bars(axes[0][j], values(rows, component=comp), scen, "MiB" if j == 0 else "")
        panel(axes[0][j], j, title)
    save(fig, outdir, "memory")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="indir", default="results/bench")
    ap.add_argument("--out", default="results/bench/figures")
    ap.add_argument("--run-id", type=run_ids_arg, help="comma-separated run ids (default: latest)")
    ap.add_argument("--drop", type=drop_arg, default=[], help="comma-separated run_id/scenario/suite to leave out")
    args = ap.parse_args()
    latency, throughput, resources = load(args.indir, args.run_id, args.drop)
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
