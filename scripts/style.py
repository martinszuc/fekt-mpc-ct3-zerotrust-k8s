"""Shared figure style (scripts/zt.mplstyle) and fixed label, color and marker per configuration.

Figures use the descriptive configuration names, never the codes. Color follows the configuration,
never its rank (validated categorical order, slots 1 to 6).
"""
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

ORDER = ["S0", "S1", "S2a", "S2b-plain", "S2b", "S3"]
LABEL = {"S0": "baseline", "S1": "segmentation", "S2a": "node encryption", "S2b-plain": "mesh without mTLS",
         "S2b": "mesh mTLS", "S3": "L7 authorization"}
COLOR = {"S0": "#2a78d6", "S1": "#eb6834", "S2a": "#1baf7a", "S2b-plain": "#eda100", "S2b": "#e87ba4", "S3": "#008300"}
MARKER = {"S0": "o", "S1": "s", "S2a": "^", "S2b-plain": "v", "S2b": "D", "S3": "P"}
INK, MUTED = "#2b2b2b", "#6b6b6b"

plt.style.use(os.path.join(os.path.dirname(os.path.abspath(__file__)), "zt.mplstyle"))


def label(s):
    return LABEL.get(s, s)


def color(s):
    return COLOR.get(s, MUTED)


def panel(ax, i, text):
    """panel label '(a) text' above the axes, left-aligned; the caption in the report carries the title"""
    ax.set_title(f"({chr(ord('a') + i)}) {text}")


def save(fig, outdir, name):
    os.makedirs(outdir, exist_ok=True)
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(outdir, f"{name}.{ext}"))
    plt.close(fig)
    print(f"{outdir}/{name}.pdf")
