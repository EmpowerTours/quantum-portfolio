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

# A "+X% lift" headline with no significance test is the claim this project
# exists to avoid making. Compute Fisher exact on the raw success counts and
# say plainly whether the difference is distinguishable from chance, and draw
# the random-guess baseline so the bars are readable against something.
pval = None
if results[1].get("counts") and results[2].get("counts"):
    from scipy.stats import fisher_exact
    shots = sum(results[1]["counts"].values())
    a, b = round(raw * shots), round(mit * shots)
    _, pval = fisher_exact([[a, shots - a], [b, shots - b]])

null_u = data.get("null_p_optimal_uniform")
if null_u:
    ax.axhline(null_u, ls="--", c="#E45756", lw=1.2,
               label=f"uniform random  {null_u:.5f}")
    ax.legend(fontsize=8, loc="upper right")

ax.set_ylabel("P(optimal portfolio)")
ax.set_ylim(0, max(p_opt) * 1.18)
sig = ("" if pval is None else
       f"  ·  Fisher exact p = {pval:.5f} "
       f"({'significant' if pval < 0.05 else 'NOT significant'}, n=1 per arm)")
ax.set_title(f"QAOA portfolio optimization on {data['backend']} "
             f"({data.get('universe','?')} universe)\n"
             f"Error mitigation {lift:+.0f}% vs raw{sig}")
ax.spines[["top", "right"]].set_visible(False)
ax.grid(axis="y", alpha=0.3)

plt.tight_layout()
Path("outputs").mkdir(exist_ok=True)
plt.savefig("outputs/p_optimal.png", dpi=140)
print("saved outputs/p_optimal.png")
print(f"  raw P(opt)       = {raw:.4f}")
print(f"  mitigated P(opt) = {mit:.4f}")
print(f"  mitigation lift  = {lift:+.1f}%")
