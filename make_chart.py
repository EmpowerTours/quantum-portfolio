"""Generate the headline benchmark chart from outputs/hardware_run.json."""
from __future__ import annotations

import json
from pathlib import Path

import matplotlib.pyplot as plt

data = json.loads(Path("outputs/hardware_run.json").read_text())
results = data["results"]
labels = ["Classical\n(exact)"] + [r["method"].replace("QAOA ", "QAOA\n") for r in results]
p_opt = [1.0] + [r["p_optimal"] for r in results]
colors = ["#222222", "#1f77b4", "#d62728", "#2ca02c"]

fig, ax = plt.subplots(figsize=(9, 5.2))
bars = ax.bar(labels, p_opt, color=colors)
for b, v in zip(bars, p_opt):
    ax.text(b.get_x() + b.get_width() / 2, v + 0.015, f"{v:.3f}",
            ha="center", va="bottom", fontsize=10)

raw, mit = results[1]["p_optimal"], results[2]["p_optimal"]
lift = (mit - raw) / raw * 100 if raw > 0 else 0
ax.set_ylabel("P(optimal portfolio)")
ax.set_ylim(0, max(p_opt) * 1.18)
ax.set_title(f"QAOA portfolio optimization on {data['backend']}\n"
             f"Error mitigation lifts P(optimal) by {lift:+.0f}% over raw hardware")
ax.spines[["top", "right"]].set_visible(False)
ax.grid(axis="y", alpha=0.3)

plt.tight_layout()
Path("outputs").mkdir(exist_ok=True)
plt.savefig("outputs/p_optimal.png", dpi=140)
print("saved outputs/p_optimal.png")
print(f"  raw P(opt)       = {raw:.4f}")
print(f"  mitigated P(opt) = {mit:.4f}")
print(f"  mitigation lift  = {lift:+.1f}%")
