"""
Figure 3: All 11 English Phase 1 plugins by error-adjusted ASR (horizontal bar).
Numbers from output/english_results.json — error-adjusted (valid tests only).
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import os

os.makedirs("figures", exist_ok=True)

# Plugin → (error-adjusted ASR %, category)
# Category: harm, agentic, privacy
plugins_raw = [
    ("Self-Harm",            62, "harm"),
    ("Illegal Drugs",        50, "harm"),
    ("Hijacking",            42, "agentic"),
    ("Prompt Extraction",    36, "privacy"),
    ("Misinformation",       30, "harm"),
    ("Shell Injection",      30, "agentic"),
    ("Hate Speech",          12, "harm"),
    ("Violent Crime",        10, "harm"),
    ("PII Extraction",       10, "privacy"),
    ("Excessive Agency",      0, "agentic"),
    ("RBAC Escalation",       0, "agentic"),
]

plugins_raw.sort(key=lambda x: x[1])
labels  = [p[0] for p in plugins_raw]
values  = [p[1] for p in plugins_raw]
cats    = [p[2] for p in plugins_raw]

COLOR_MAP = {
    "harm":    "#C0392B",
    "agentic": "#8E44AD",
    "privacy": "#16A085",
}
colors = [COLOR_MAP[c] for c in cats]

GRID_COLOR = "#E8E8E8"

fig, ax = plt.subplots(figsize=(7, 5.5))
fig.patch.set_facecolor("white")
ax.set_facecolor("white")

bars = ax.barh(labels, values, color=colors, alpha=0.88, height=0.6, zorder=3)

for bar, val in zip(bars, values):
    if val > 0:
        ax.text(val + 1, bar.get_y() + bar.get_height() / 2,
                f"{val}%", va="center", ha="left", fontsize=9, color="#333333")
    else:
        ax.text(1, bar.get_y() + bar.get_height() / 2,
                "0%", va="center", ha="left", fontsize=9, color="#999999")

ax.set_xlabel("Attack Success Rate (%) — error-adjusted", fontsize=10)
ax.set_xlim(0, 80)
ax.xaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:.0f}%"))
ax.xaxis.grid(True, color=GRID_COLOR, linewidth=0.8, zorder=0)
ax.set_axisbelow(True)
for spine in ["top", "right", "bottom"]:
    ax.spines[spine].set_visible(False)
ax.spines["left"].set_color("#CCCCCC")
ax.tick_params(axis="both", which="both", length=0)
ax.tick_params(axis="y", labelsize=10)

# Category legend
import matplotlib.patches as mpatches
legend_handles = [mpatches.Patch(color=v, alpha=0.88, label=k.capitalize())
                  for k, v in COLOR_MAP.items()]
ax.legend(handles=legend_handles, frameon=False, fontsize=9,
          loc="lower right", bbox_to_anchor=(1.0, 0.0))

plt.tight_layout(pad=1.2)
plt.savefig("figures/english_plugins.pdf", dpi=150, bbox_inches="tight")
plt.savefig("figures/english_plugins.png", dpi=150, bbox_inches="tight")
print("Saved figures/english_plugins.pdf")
