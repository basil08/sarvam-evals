"""
Figure 4: Dual-judge blind spot comparison — English vs Hindi.
Shows agree/disagree breakdown for all Claude FAIL cases in each language.
English: 137 FAIL cases (63 agree, 73 blind spots, 1 error)
Hindi:    28 FAIL cases ( 0 agree, 28 blind spots, 0 errors)
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np
import os

os.makedirs("figures", exist_ok=True)

languages = ["English", "Hindi"]
agree      = [63, 0]
blind_spot = [73, 28]

AGREE_COLOR      = "#2ECC71"
BLIND_COLOR      = "#E74C3C"
GRID_COLOR       = "#E8E8E8"

fig, ax = plt.subplots(figsize=(6, 4))
fig.patch.set_facecolor("white")
ax.set_facecolor("white")

x = np.arange(len(languages))
width = 0.45

b1 = ax.bar(x, agree, width, color=AGREE_COLOR, alpha=0.88, label="Both judges agree (FAIL)", zorder=3)
b2 = ax.bar(x, blind_spot, width, bottom=agree, color=BLIND_COLOR, alpha=0.88,
            label="Blind spot (Claude FAIL, Sarvam PASS)", zorder=3)

totals = [a + b for a, b in zip(agree, blind_spot)]

for i, (a, b, tot) in enumerate(zip(agree, blind_spot, totals)):
    # Blind spot % label inside top bar
    pct = b / tot * 100
    ax.text(x[i], a + b / 2, f"{pct:.0f}%\nblind spot",
            ha="center", va="center", fontsize=11, fontweight="bold",
            color="white")
    # Total label above bar
    ax.text(x[i], tot + 1.5, f"n={tot}", ha="center", va="bottom", fontsize=9, color="#555555")

ax.set_xticks(x)
ax.set_xticklabels(languages, fontsize=13, fontweight="bold")
ax.set_ylabel("Claude FAIL cases", fontsize=11)
ax.set_ylim(0, 155)
ax.yaxis.grid(True, color=GRID_COLOR, linewidth=0.8, zorder=0)
ax.set_axisbelow(True)
for spine in ["top", "right", "left"]:
    ax.spines[spine].set_visible(False)
ax.spines["bottom"].set_color("#CCCCCC")
ax.tick_params(axis="both", which="both", length=0)

legend = ax.legend(
    handles=[
        mpatches.Patch(color=AGREE_COLOR, alpha=0.88, label="Both judges agree (FAIL)"),
        mpatches.Patch(color=BLIND_COLOR, alpha=0.88, label="Blind spot (Sarvam missed it)"),
    ],
    frameon=False, fontsize=9, loc="upper right"
)

plt.tight_layout(pad=1.2)
plt.savefig("figures/blindspot.pdf", dpi=150, bbox_inches="tight")
plt.savefig("figures/blindspot.png", dpi=150, bbox_inches="tight")
print("Saved figures/blindspot.pdf")
