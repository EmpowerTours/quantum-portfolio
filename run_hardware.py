"""Real IBM hardware run: QAOA on a Heron QPU, raw vs error-mitigated.

Methodology:
  1. Tune QAOA angles on a noiseless simulator (free).
  2. Run the SAME tuned circuit on a real QPU twice -- raw and mitigated.
  3. Score each by both P(optimal) and the approximation ratio.

Approximation ratio = (E[random] - E[sampled]) / (E[random] - E[optimal])
  1.0 = always finds the optimum; 0.0 = no better than random. The smoother the
  metric, the cleaner the visible effect of error mitigation on hardware.
"""
from __future__ import annotations

import json
import time
from pathlib import Path

import numpy as np

from src.data import get_market_data
from src.problem import build_problem
from src.qaoa_hw import (build_cost_hamiltonian, optimize_angles, sample_hardware,
                         sample_simulator)
from src.hardware import get_service
from src.solvers import portfolio_metrics, solve_exact

TICKERS = ["PPLT", "GLD", "SLV", "AAPL", "MSFT", "NVDA", "JPM", "XOM"]
BUDGET = 3
RISK_FACTOR = 0.5
REPS = 2
SHOTS = 4096


def _random_baseline(problem) -> float:
    """Expected objective over all 2^n bitstrings (uniform random)."""
    n = problem.num_assets
    total, count = 0.0, 0
    for mask in range(1 << n):
        x = np.array([(mask >> i) & 1 for i in range(n)], dtype=float)
        total += float(problem.qp.objective.evaluate(x))
        count += 1
    return total / count


def approximation_ratio(score, problem, optimal_obj, random_obj) -> float:
    return (random_obj - score.best_objective) / (random_obj - optimal_obj)


def main() -> None:
    print("Fetching market data...")
    market = get_market_data(TICKERS, period="2y")
    problem = build_problem(market, budget=BUDGET, risk_factor=RISK_FACTOR)
    exact = solve_exact(problem)
    print(f"  optimal: {[market.tickers[i] for i in exact.selection]} "
          f"obj={exact.objective:.4f}\n")

    random_obj = _random_baseline(problem)

    print(f"Tuning QAOA(reps={REPS}) on simulator...")
    t0 = time.perf_counter()
    ansatz, params = optimize_angles(problem, reps=REPS, maxiter=80)
    print(f"  tuned in {time.perf_counter()-t0:.1f}s\n")

    print("Sampling on simulator (reference)...")
    sim = sample_simulator(problem, ansatz, params, exact.selection, shots=SHOTS)

    print("Connecting to IBM Quantum...")
    svc = get_service()
    backend = svc.least_busy(operational=True, simulator=False, min_num_qubits=8)
    print(f"  backend: {backend.name}  qubits={backend.num_qubits}\n")

    print("Submitting RAW hardware job...")
    t0 = time.perf_counter()
    hw_raw = sample_hardware(problem, ansatz, params, exact.selection, backend,
                             mitigate=False, shots=SHOTS)
    print(f"  done in {time.perf_counter()-t0:.1f}s  job_id={hw_raw.job_id}\n")

    print("Submitting MITIGATED hardware job (DD + measurement twirling)...")
    t0 = time.perf_counter()
    hw_mit = sample_hardware(problem, ansatz, params, exact.selection, backend,
                             mitigate=True, shots=SHOTS)
    print(f"  done in {time.perf_counter()-t0:.1f}s  job_id={hw_mit.job_id}\n")

    rows = [
        ("Classical (exact)", exact.selection, exact.objective, 1.0, "-"),
    ]
    for s in (sim, hw_raw, hw_mit):
        ar = approximation_ratio(s, problem, exact.objective, random_obj)
        rows.append((s.method, s.best_selection, s.best_objective, s.p_optimal, ar))

    print(f"{'Method':<26}{'Selection':<22}{'Obj':>9}{'P(opt)':>9}{'AR':>8}")
    print("-" * 74)
    for m, sel, obj, popt, ar in rows:
        sel_str = ", ".join(market.tickers[i] for i in sel) if sel else "(none)"
        ar_str = f"{ar:.3f}" if isinstance(ar, float) else ar
        popt_str = f"{popt:.3f}" if isinstance(popt, float) else "-"
        print(f"{m:<26}{sel_str:<22}{obj:>9.4f}{popt_str:>9}{ar_str:>8}")

    Path("outputs").mkdir(exist_ok=True)
    Path("outputs/hardware_run.json").write_text(json.dumps({
        "backend": backend.name,
        "shots": SHOTS,
        "reps": REPS,
        "tickers": TICKERS,
        "budget": BUDGET,
        "optimal": {"selection": exact.selection, "objective": exact.objective},
        "random_baseline_objective": random_obj,
        "results": [
            {"method": s.method, "best_selection": s.best_selection,
             "best_objective": s.best_objective, "p_optimal": s.p_optimal,
             "job_id": s.job_id} for s in (sim, hw_raw, hw_mit)
        ],
    }, indent=2))
    print("\nSaved outputs/hardware_run.json")


if __name__ == "__main__":
    main()
