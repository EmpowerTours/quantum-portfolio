"""Real IBM hardware run: QAOA on a Heron QPU, raw vs error-mitigated.

Methodology:
  1. Tune QAOA angles on a noiseless simulator (free).
  2. Run the SAME tuned circuit on a real QPU twice -- raw and mitigated.
  3. Score each by both P(optimal) and the approximation ratio.

Approximation ratio = (E[random] - E[sampled]) / (E[random] - E[optimal])
  1.0 = always finds the optimum; 0.0 = no better than random. The smoother the
  metric, the cleaner the visible effect of error mitigation on hardware.

Universe:
  --universe stocks  → cached MVP stock universe (default; cheaper QPU time)
  --universe defi    → live Monad-primary DeFi pool universe from DeFiLlama
                       (matches the Streamlit app and the README pitch)
"""
from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path

import numpy as np

from src.data import get_market_data
from src.problem import build_problem
from src.qaoa_hw import (build_cost_hamiltonian, optimize_angles, sample_hardware,
                         sample_simulator)
from src.xy_qaoa import optimize_xy_qaoa
from src.hardware import get_service
from src.solvers import portfolio_metrics, solve_exact

STOCK_TICKERS = ["PPLT", "GLD", "SLV", "AAPL", "MSFT", "NVDA", "JPM", "XOM"]
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
    """Best-of-N approximation ratio. RETAINED FOR CONTINUITY ONLY.

    This reaches 1.000 if ANY of the shots hits the optimum, so on an 8-asset
    instance a uniform random sampler achieves it with probability
    1 - (255/256)^4096 ~ 0.9999999. It is not a measure of circuit quality.
    Use `mean_approximation_ratio` below to judge the run.
    """
    return (random_obj - score.best_objective) / (random_obj - optimal_obj)


def mean_approximation_ratio(score, optimal_obj, random_feasible_obj) -> float | None:
    """AR computed from the MEAN energy over feasible shots — an expectation,
    so noise scores ~0 and only a circuit that concentrates amplitude on good
    states scores near 1. Baseline is the mean over uniformly-random FEASIBLE
    bitstrings, so numerator and denominator share a support."""
    if score.mean_feasible_objective is None:
        return None
    denom = random_feasible_obj - optimal_obj
    if denom == 0:
        return None
    return (random_feasible_obj - score.mean_feasible_objective) / denom


def _random_feasible_baseline(problem) -> float:
    """Expected objective over uniformly-random FEASIBLE selections (|x| == k)."""
    import itertools
    n, k = problem.num_assets, problem.budget
    tot, cnt = 0.0, 0
    for combo in itertools.combinations(range(n), k):
        x = np.zeros(n); x[list(combo)] = 1
        tot += float(problem.qp.objective.evaluate(x)); cnt += 1
    return tot / cnt


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--universe", choices=("stocks", "defi"), default="stocks",
                    help="asset universe to optimise over")
    ap.add_argument("--days", type=int, default=365,
                    help="(defi only) history window in days")
    ap.add_argument("--budget", type=int, default=BUDGET)
    ap.add_argument("--reps", type=int, default=None,
                    help="QAOA layers. Default: 2 for penalty, 3 for xy — the xy "
                         "path COLLAPSES to a single deterministic state at reps=2.")
    ap.add_argument("--xy-topology", choices=("ring", "complete"), default="ring",
                    help="ring is both cheaper and better on heavy-hex: measured "
                         "P(opt) 0.2078 at 454 two-qubit gates, vs complete's "
                         "0.0808 at 1572.")
    ap.add_argument("--mixer", choices=("penalty", "xy"), default="penalty",
                    help="penalty: X mixer over the full 2^n space, budget enforced "
                         "as a quadratic penalty (the original path). xy: XY mixer "
                         "with feasible-subspace initialisation, which CONSERVES "
                         "Hamming weight so every sample satisfies the budget by "
                         "construction. xy raises the random-guess ceiling from "
                         "1/2^n to 1/C(n,k) and drops the dense penalty layer that "
                         "dominates two-qubit gate count after routing.")
    args = ap.parse_args()

    if args.universe == "defi":
        from src.defi_data import get_defi_market_data
        print(f"Fetching live DeFi yields ({args.days} days) from DeFiLlama...")
        market = get_defi_market_data(days=args.days)
    else:
        print("Fetching stock market data...")
        market = get_market_data(STOCK_TICKERS, period="2y")

    problem = build_problem(market, budget=args.budget, risk_factor=RISK_FACTOR)
    exact = solve_exact(problem)
    print(f"  optimal: {[market.tickers[i] for i in exact.selection]} "
          f"obj={exact.objective:.4f}\n")

    random_obj = _random_baseline(problem)

    n, k = problem.num_assets, args.budget
    uniform_null = 1.0 / (2 ** n)
    feasible_null = 1.0 / math.comb(n, k)
    print(f"Random-guess baselines: uniform 1/2^{n} = {uniform_null:.5f}"
          f"  |  uniform-over-feasible 1/C({n},{k}) = {feasible_null:.5f}")

    t0 = time.perf_counter()
    reps = args.reps if args.reps is not None else (3 if args.mixer == "xy" else REPS)
    if args.mixer == "xy":
        if reps < 3:
            raise SystemExit(
                f"--mixer xy needs --reps >= 3; at reps={reps} the optimiser "
                "minimises <H> by rotating deterministically onto ONE basis "
                "state, giving 100% feasibility and P(optimal) = 0."
            )
        print(f"Tuning XY-mixer QAOA(reps={reps}, topology={args.xy_topology}) "
              "on simulator (feasible-subspace init, TQA warm starts)...")
        bound, angles, energy = optimize_xy_qaoa(problem, reps=reps,
                                                 topology=args.xy_topology)
        ansatz, params = bound, {}          # already bound
        print(f"  tuned in {time.perf_counter()-t0:.1f}s  best energy {energy:.6f}\n")
    else:
        print(f"Tuning penalty-QAOA(reps={reps}) on simulator...")
        ansatz, params = optimize_angles(problem, reps=reps, maxiter=80)
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
    random_feasible_obj = _random_feasible_baseline(problem)
    for s in (sim, hw_raw, hw_mit):
        ar = approximation_ratio(s, problem, exact.objective, random_obj)
        rows.append((s.method, s.best_selection, s.best_objective, s.p_optimal, ar))

    print(f"{'Method':<24}{'Obj':>9}{'P(opt)':>9}{'feas%':>8}{'meanAR':>8}{'2Q':>6}{'depth':>7}")
    print("-" * 71)
    print(f"{'Classical (exact)':<24}{exact.objective:>9.4f}{1.0:>9.3f}{'-':>8}{'-':>8}{'-':>6}{'-':>7}")
    for sc in (sim, hw_raw, hw_mit):
        mar = mean_approximation_ratio(sc, exact.objective, random_feasible_obj)
        print(f"{sc.method:<24}{sc.best_objective:>9.4f}{sc.p_optimal:>9.4f}"
              f"{sc.feasible_fraction*100:>7.1f}%"
              f"{(f'{mar:.3f}' if mar is not None else '-'):>8}"
              f"{(sc.two_qubit_gates if sc.two_qubit_gates is not None else '-'):>6}"
              f"{(sc.circuit_depth if sc.circuit_depth is not None else '-'):>7}")
    print()
    print(f"  P(opt) null: uniform {uniform_null:.5f} | uniform-over-feasible {feasible_null:.5f}")
    print(f"  A run whose feasible% ~= {100/2**n*math.comb(n,k):.1f}% and P(opt) ~= "
          f"{uniform_null:.5f} is indistinguishable from noise.")

    Path("outputs").mkdir(exist_ok=True)
    out_name = "hardware_run.json" if args.universe == "stocks" else "hardware_run_defi.json"
    Path(f"outputs/{out_name}").write_text(json.dumps({
        "backend": backend.name,
        "universe": args.universe,
        "shots": SHOTS,
        "reps": reps,
        "xy_topology": args.xy_topology if args.mixer == "xy" else None,
        "tickers": list(market.tickers),
        "budget": args.budget,
        "optimal": {"selection": exact.selection, "objective": exact.objective},
        "random_baseline_objective": random_obj,
        "mixer": args.mixer,
        "null_p_optimal_uniform": uniform_null,
        "null_p_optimal_uniform_feasible": feasible_null,
        "random_feasible_baseline_objective": random_feasible_obj,
        "results": [
            {"method": sc.method, "best_selection": sc.best_selection,
             "best_objective": sc.best_objective, "p_optimal": sc.p_optimal,
             "feasible_fraction": sc.feasible_fraction,
             "mean_feasible_objective": sc.mean_feasible_objective,
             "mean_approximation_ratio":
                 mean_approximation_ratio(sc, exact.objective, random_feasible_obj),
             "two_qubit_gates": sc.two_qubit_gates,
             "circuit_depth": sc.circuit_depth,
             "counts": sc.counts,
             "job_id": sc.job_id} for sc in (sim, hw_raw, hw_mit)
        ],
    }, indent=2))
    print(f"\nSaved outputs/{out_name}")


if __name__ == "__main__":
    main()
