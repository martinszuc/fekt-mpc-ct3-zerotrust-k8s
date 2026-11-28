"""Shared figure style (scripts/zt.mplstyle) and fixed label, color and marker per configuration.

Figures use the descriptive configuration names, never the codes. Color follows the configuration,
never its rank (validated categorical order, slots 1 to 6).
"""
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.ticker import FuncFormatter  # noqa: E402

ORDER = ["S0", "S1", "S2a", "S2b-plain", "S2b", "S3"]
LABEL = {"S0": "bez ochrany", "S1": "segmentácia siete", "S2a": "šifrovanie medzi uzlami",
         "S2b-plain": "mesh bez mTLS", "S2b": "mTLS medzi službami", "S3": "L7 autorizácia"}
COLOR = {"S0": "#2a78d6", "S1": "#eb6834", "S2a": "#1baf7a", "S2b-plain": "#eda100", "S2b": "#e87ba4", "S3": "#008300"}
MARKER = {"S0": "o", "S1": "s", "S2a": "^", "S2b-plain": "v", "S2b": "D", "S3": "P"}
# hatching keeps S2b-plain apart from S2b in grayscale and marks it as measurement-only;
# dots keep L7 authorization apart from node encryption (similar greens in print)
HATCH = {"S2b-plain": "////", "S3": "...."}
INK, MUTED = "#2b2b2b", "#6b6b6b"
# text width of the report (426.8 pt), so 7-8 pt fonts print at 7-8 pt
FIGW = 426.8 / 72

plt.style.use(os.path.join(os.path.dirname(os.path.abspath(__file__)), "zt.mplstyle"))


def label(s):
    return LABEL.get(s, s)


def color(s):
    return COLOR.get(s, MUTED)


def num(v, _=None):
    """plain number with a decimal comma (no locale: CI has no sk_SK)"""
    return f"{v:g}".replace(".", ",")


def comma(ax, axis="y"):
    getattr(ax, f"{axis}axis").set_major_formatter(FuncFormatter(num))


def panel(ax, i, text):
    """panel label '(a) text' above the axes, left-aligned; the caption in the report carries the title"""
    ax.set_title(f"({chr(ord('a') + i)}) {text}")


def save(fig, outdir, name):
    os.makedirs(outdir, exist_ok=True)
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(outdir, f"{name}.{ext}"))
    plt.close(fig)
    print(f"{outdir}/{name}.pdf")
