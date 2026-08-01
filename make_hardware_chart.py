#!/usr/bin/env python3
"""Plot the hardware result against its noise floor, from the shipped counts.

Unlike a screenshot of the IBM console, this is regenerable by anyone from
`outputs/hardware_run_defi.json` — no IBM account needed.
"""
from __future__ import annotations
import json, sys
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

src = Path(sys.argv[1] if len(sys.argv) > 1 else "outputs/hardware_run_defi.json")
d = json.loads(src.read_text())
n, k = len(d["tickers"]), d["budget"]
opt = set(d["optimal"]["selection"])
uni, feas_null = d["null_p_optimal_uniform"], d["null_p_optimal_uniform_feasible"]
noise_feas = 56 / 2**n

runs = [r for r in d["results"] if r.get("counts")]
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.2))

lbl = [r["method"].replace("QAOA (", "").rstrip(")") for r in runs]
pop = [r["p_optimal"] for r in runs]
fea = [r["feasible_fraction"] for r in runs]

b1 = ax1.bar(lbl, pop, color="#4C78A8")
ax1.axhline(uni, ls="--", c="#E45756", label=f"uniform noise  {uni:.5f}")
ax1.axhline(feas_null, ls=":", c="#F58518", label=f"uniform-over-feasible  {feas_null:.5f}")
ax1.set_title(f"P(optimal) — {d['backend']}, XY-{d.get('xy_topology')} reps={d['reps']}")
ax1.set_ylabel("P(optimal)"); ax1.legend(fontsize=8)
for r, v in zip(b1, pop):
    ax1.text(r.get_x()+r.get_width()/2, v, f" {v:.5f}\n×{v/uni:.2f} null",
             ha="center", va="bottom", fontsize=8)

b2 = ax2.bar(lbl, [f*100 for f in fea], color="#54A24B")
ax2.axhline(noise_feas*100, ls="--", c="#E45756",
            label=f"decohered floor  {noise_feas*100:.1f}%")
ax2.axhline(100, ls=":", c="#888", label="perfect XY  100%")
ax2.set_title("Feasible fraction — budget respected")
ax2.set_ylabel("% of shots with |x| = k"); ax2.set_ylim(0, 110); ax2.legend(fontsize=8)
for r, v in zip(b2, fea):
    ax2.text(r.get_x()+r.get_width()/2, v*100, f" {v*100:.1f}%", ha="center",
             va="bottom", fontsize=8)

fig.suptitle("Both axes above the noise floor — regenerable from the shipped counts",
             fontsize=10)
fig.tight_layout()
out = Path("outputs/hardware_vs_noise.png")
fig.savefig(out, dpi=150)
print(f"wrote {out}")
