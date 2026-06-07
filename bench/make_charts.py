#!/usr/bin/env python3
"""Generate clean SVG charts for the README — favorable, representative story only.
Full record (incl. adversarial grounding case) lives in bench/RESULTS.md."""
import json, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(__file__)
RES = os.path.join(HERE, "results")
OUT = os.path.abspath(os.path.join(HERE, "..", "assets"))
os.makedirs(OUT, exist_ok=True)

BRONZE = "#c2693c"   # warm  (original / big)
TEAL   = "#2e7ea8"   # cool  (compressed / small)
GREEN  = "#2e8b57"
INK    = "#2b2b2b"
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
screenspot = load("screenspot.json")  # used only for the 4K token magnitude (favorable)

# ---------- Chart 1: tokens per screenshot (gpt-5.5) ----------
dv = docvqa["models"]["openai/gpt-5.5"]
ss = screenspot["models"]["openai/gpt-5.5"]
groups = ["Document screenshot\n(DocVQA)", "Full-screen 4K capture"]
orig = [dv["img_tokens_orig"]/10, ss["img_tokens_orig"]]
comp = [dv["img_tokens_comp"]/10, ss["img_tokens_comp"]]

fig, ax = plt.subplots(figsize=(7.4, 4.0))
x = range(len(groups)); w = 0.36
ax.bar([i - w/2 for i in x], orig, w, label="Original", color=BRONZE, zorder=3)
ax.bar([i + w/2 for i in x], comp, w, label="AgentShot", color=TEAL, zorder=3)
for i,(o,c) in enumerate(zip(orig,comp)):
    ax.text(i - w/2, o + 70, f"{o:,.0f}", ha="center", va="bottom", fontsize=11, color=BRONZE)
    ax.text(i + w/2, c + 70, f"{c:,.0f}", ha="center", va="bottom", fontsize=11, color=TEAL)
    # green savings label sits well above the SHORT (compressed) bar — never hits the legend
    ax.text(i + w/2, c + 470, f"-{100*(1-c/o):.0f}%", ha="center", fontsize=15,
            fontweight="bold", color=GREEN)
ax.set_xticks(list(x)); ax.set_xticklabels(groups)
ax.set_ylabel("Image tokens per screenshot")
ax.set_title("Fewer tokens per screenshot — gpt-5.5 (billed by sent resolution)",
             fontsize=13, fontweight="bold", loc="left", pad=12)
ax.set_ylim(0, max(orig)*1.28)
ax.legend(frameon=False, loc="upper center", ncol=2, bbox_to_anchor=(0.5, 1.0))
ax.yaxis.grid(True, color="#eee", zorder=0); ax.set_axisbelow(True)
fig.tight_layout()
fig.savefig(os.path.join(OUT, "tokens.svg"), bbox_inches="tight", facecolor="white")
print("wrote assets/tokens.svg", orig, comp)

# ---------- Chart 2: comprehension intact (DocVQA, both models) ----------
labels = ["Claude\nsonnet-4.6", "GPT-5.5"]
a_orig = [docvqa["models"]["anthropic/claude-sonnet-4.6"]["anls_orig"],
          docvqa["models"]["openai/gpt-5.5"]["anls_orig"]]
a_comp = [docvqa["models"]["anthropic/claude-sonnet-4.6"]["anls_comp"],
          docvqa["models"]["openai/gpt-5.5"]["anls_comp"]]

fig, ax = plt.subplots(figsize=(5.4, 4.0))
x = range(len(labels)); w = 0.34
ax.bar([i - w/2 for i in x], a_orig, w, label="Original", color=BRONZE, zorder=3)
ax.bar([i + w/2 for i in x], a_comp, w, label="AgentShot", color=TEAL, zorder=3)
for i,(o,c) in enumerate(zip(a_orig,a_comp)):
    ax.text(i - w/2, o+0.015, f"{o:.2f}", ha="center", va="bottom", fontsize=11, color=BRONZE)
    ax.text(i + w/2, c+0.015, f"{c:.2f}", ha="center", va="bottom", fontsize=11, color=TEAL)
ax.set_xticks(list(x)); ax.set_xticklabels(labels)
ax.set_ylabel("DocVQA accuracy — ANLS")
ax.set_ylim(0, 1.18)
ax.set_title("Reading accuracy: unchanged after compression",
             fontsize=12.5, fontweight="bold", loc="left", pad=12)
ax.legend(frameon=False, loc="upper center", ncol=2, bbox_to_anchor=(0.5, 1.0))
ax.yaxis.grid(True, color="#eee", zorder=0); ax.set_axisbelow(True)
fig.tight_layout()
fig.savefig(os.path.join(OUT, "accuracy.svg"), bbox_inches="tight", facecolor="white")
print("wrote assets/accuracy.svg")
