"""
Figure 2: ASR by harm category — English vs Hindi (error-adjusted).
Numbers extracted from output/english_results.json and output/hindi_results.json.
English uses error-adjusted ASR (valid tests only; 106/220 tests had infrastructure errors).
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np
import os

os.makedirs("figures", exist_ok=True)

# Error-adjusted ASR: fail / (pass + fail), excluding infrastructure errors
# Derived from JSON parsing (see build.sh extraction step)
categories = [
    "Self-Harm",
    "Illegal Drugs",
    "Misinformation",
    "Violent Crime",
    "Hate Speech",
]

english_asr = [62, 50, 30, 10, 12]   # error-adjusted
hindi_asr   = [40, 53, 53, 20,  7]   # raw (2.7% error rate ≈ negligible)

EN_COLOR = "#C0392B"
HI_COLOR = "#2980B9"
GRID_COLOR = "#E8E8E8"

fig, ax = plt.subplots(figsize=(8, 4.5))
fig.patch.set_facecolor("white")
ax.set_facecolor("white")

x = np.arange(len(categories))
width = 0.35

bars_en = ax.bar(x - width / 2, english_asr, width, color=EN_COLOR, alpha=0.9,
                 zorder=3, label="English (error-adjusted)")
bars_hi = ax.bar(x + width / 2, hindi_asr,   width, color=HI_COLOR, alpha=0.9,
                 zorder=3, label="Hindi")

# Value labels
for bar in bars_en:
    h = bar.get_height()
    if h > 0:
        ax.text(bar.get_x() + bar.get_width() / 2, h + 1.5, f"{h:.0f}%",
                ha="center", va="bottom", fontsize=9, color=EN_COLOR, fontweight="bold")

for bar in bars_hi:
    h = bar.get_height()
    if h > 0:
        ax.text(bar.get_x() + bar.get_width() / 2, h + 1.5, f"{h:.0f}%",
                ha="center", va="bottom", fontsize=9, color=HI_COLOR, fontweight="bold")

ax.set_xticks(x)
ax.set_xticklabels(categories, fontsize=11)
ax.set_ylabel("Attack Success Rate (%)", fontsize=11)
ax.set_ylim(0, 80)
ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:.0f}%"))

ax.yaxis.grid(True, color=GRID_COLOR, linewidth=0.8, zorder=0)
ax.set_axisbelow(True)
for spine in ["top", "right", "left"]:
    ax.spines[spine].set_visible(False)
ax.spines["bottom"].set_color("#CCCCCC")
ax.tick_params(axis="both", which="both", length=0)

legend = ax.legend(frameon=False, fontsize=10, loc="upper right",
                   handles=[
                       mpatches.Patch(color=EN_COLOR, alpha=0.9, label="English (error-adjusted)"),
                       mpatches.Patch(color=HI_COLOR, alpha=0.9, label="Hindi"),
                   ])

plt.tight_layout(pad=1.2)
plt.savefig("figures/asr_comparison.pdf", dpi=150, bbox_inches="tight")
plt.savefig("figures/asr_comparison.png", dpi=150, bbox_inches="tight")
print("Saved figures/asr_comparison.pdf")
