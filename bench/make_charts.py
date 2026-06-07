#!/usr/bin/env python3
"""Generate clean SVG charts from bench/results/*.json for the README."""
import json, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager

HERE = os.path.dirname(__file__)
RES = os.path.join(HERE, "results")
OUT = os.path.abspath(os.path.join(HERE, "..", "assets"))
os.makedirs(OUT, exist_ok=True)

BRONZE = "#c2693c"   # warm  (original / big)
TEAL   = "#2e7ea8"   # cool  (compressed / small)
INK     = "#2b2b2b"
MUTED  = "#8a8a8a"

plt.rcParams.update({
    "font.size": 12, "text.color": INK, "axes.edgecolor": "#d8d8d8",
    "axes.labelcolor": INK, "xtick.color": INK, "ytick.color": MUTED,
    "svg.fonttype": "none", "axes.spines.top": False, "axes.spines.right": False,
})

def load(name):
    with open(os.path.join(RES, name)) as f:
        return json.load(f)

docvqa = load("docvqa.json")
screenspot = load("screenspot.json")

# ---------- Chart 1: tokens per screenshot (gpt-5.5) ----------
def per_img(d, model, key, n=10):
    v = d["models"][model][key]
    return None if v is None else (v / n if v > 50 else v)  # docvqa stored totals; screenspot stored avg

# docvqa stored totals over 10; screenspot stored per-image averages
dv = docvqa["models"]["openai/gpt-5.5"]
ss = screenspot["models"]["openai/gpt-5.5"]
groups = ["DocVQA\n(document Q&A)", "ScreenSpot-Pro\n(4K UI screenshots)"]
orig = [dv["img_tokens_orig"]/10, ss["img_tokens_orig"]]
comp = [dv["img_tokens_comp"]/10, ss["img_tokens_comp"]]

fig, ax = plt.subplots(figsize=(7.2, 3.8))
x = range(len(groups)); w = 0.36
b1 = ax.bar([i - w/2 for i in x], orig, w, label="Original", color=BRONZE)
b2 = ax.bar([i + w/2 for i in x], comp, w, label="AgentShot (1568px)", color=TEAL)
for i,(o,c) in enumerate(zip(orig,comp)):
    ax.text(i - w/2, o, f"{o:,.0f}", ha="center", va="bottom", fontsize=11, color=BRONZE)
    ax.text(i + w/2, c, f"{c:,.0f}", ha="center", va="bottom", fontsize=11, color=TEAL)
    pct = 100*(1 - c/o)
    ax.text(i, max(o,c)*1.16, f"-{pct:.0f}%", ha="center", fontsize=14, fontweight="bold", color="#2e8b57")
ax.set_xticks(list(x)); ax.set_xticklabels(groups)
ax.set_ylabel("Image tokens per screenshot")
ax.set_title("Token cost per screenshot — gpt-5.5 (billed by sent resolution)", fontsize=13, fontweight="bold", loc="left")
ax.set_ylim(0, max(orig)*1.32)
ax.legend(frameon=False, loc="upper right")
ax.yaxis.grid(True, color="#eee"); ax.set_axisbelow(True)
fig.tight_layout()
fig.savefig(os.path.join(OUT, "tokens.svg"), bbox_inches="tight", facecolor="white")
print("wrote assets/tokens.svg", orig, comp)

# ---------- Chart 2: accuracy original vs compressed ----------
labels = ["DocVQA\nClaude (ANLS)", "DocVQA\nGPT-5.5 (ANLS)",
          "ScreenSpot\nClaude (acc)", "ScreenSpot\nGPT-5.5 (acc)"]
a_orig = [docvqa["models"]["anthropic/claude-sonnet-4.6"]["anls_orig"],
          docvqa["models"]["openai/gpt-5.5"]["anls_orig"],
          screenspot["models"]["anthropic/claude-sonnet-4.6"]["acc_orig"],
          screenspot["models"]["openai/gpt-5.5"]["acc_orig"]]
a_comp = [docvqa["models"]["anthropic/claude-sonnet-4.6"]["anls_comp"],
          docvqa["models"]["openai/gpt-5.5"]["anls_comp"],
          screenspot["models"]["anthropic/claude-sonnet-4.6"]["acc_comp"],
          screenspot["models"]["openai/gpt-5.5"]["acc_comp"]]

fig, ax = plt.subplots(figsize=(7.6, 3.8))
x = range(len(labels)); w = 0.36
ax.bar([i - w/2 for i in x], a_orig, w, label="Original", color=BRONZE)
ax.bar([i + w/2 for i in x], a_comp, w, label="Compressed", color=TEAL)
for i,(o,c) in enumerate(zip(a_orig,a_comp)):
    ax.text(i - w/2, o+0.01, f"{o:.2f}", ha="center", va="bottom", fontsize=10, color=BRONZE)
    ax.text(i + w/2, c+0.01, f"{c:.2f}", ha="center", va="bottom", fontsize=10, color=TEAL)
ax.set_xticks(list(x)); ax.set_xticklabels(labels, fontsize=10)
ax.set_ylabel("Score (higher = better)")
ax.set_ylim(0, 1.15)
ax.set_title("Accuracy: original vs compressed  (comprehension intact; grounding is the caveat)",
             fontsize=12, fontweight="bold", loc="left")
ax.legend(frameon=False, loc="upper right", ncol=2)
ax.yaxis.grid(True, color="#eee"); ax.set_axisbelow(True)
fig.tight_layout()
fig.savefig(os.path.join(OUT, "accuracy.svg"), bbox_inches="tight", facecolor="white")
print("wrote assets/accuracy.svg")
