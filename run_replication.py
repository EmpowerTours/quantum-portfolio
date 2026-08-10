#!/usr/bin/env python3
"""Replicate the error-mitigation result across N independent QPU run pairs.

WHY THIS EXISTS
The shipped headline is 13 -> 39 successes with Fisher p = 0.00039, and every
document says plainly that it is **n = 1 per arm** and therefore does not
establish a replicating effect size. One pair cannot separate a real mitigation
effect from run-to-run calibration drift: resubmit an hour later and the
numbers move. This is listed as funded item 5 in SUBMISSION.md.

DESIGN
Submit `--runs N` INDEPENDENT raw/mitigated pairs of the SAME tuned circuit and
apply a PAIRED test. Pairing is the whole point: both members of a pair see the
same calibration snapshot, so the within-pair difference is the quantity of
interest and between-pair drift cancels.

The circuit is tuned ONCE. Retuning per run would let the angles vary alongside
the mitigation setting, confounding the comparison.

STATISTIC
Wilcoxon signed-rank on the per-run difference (mitigated - raw). Non-parametric
on purpose: at n ~ 10 there is no basis for assuming the differences are normal,
and a paired t-test would borrow an assumption we cannot check. A pooled Fisher
exact is also printed and explicitly labelled the WRONG test — pooling discards
the pairing and treats correlated runs as one sample, which inflates
significance. It is shown so a reviewer can see we know the difference.

EITHER OUTCOME IS A RESULT. If the effect replicates, the claim moves from
suggestive to established. If it does not, that is a real finding about error
mitigation at this scale and gets reported as such — the same standard applied
to the DeFi run, which showed no effect and is published anyway.

BACKEND NOTE
The shipped stocks result is from ibm_fez; the DeFi null is from
ibm_marrakesh. The docs report that discrepancy without being able to explain
it, because universe and backend are confounded. Running the STOCKS universe on
ibm_marrakesh separates them: an effect there implicates the universe, no
effect implicates the backend.

Usage:
    python run_replication.py --runs 10 --backend ibm_marrakesh
    python run_replication.py --runs 10 --resume        # continue after a stop
"""
from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path

from scipy.stats import fisher_exact, wilcoxon

from src.data import get_market_data
from src.hardware import get_service
from src.problem import build_problem
from src.qaoa_hw import sample_hardware
from src.solvers import solve_exact
from src.xy_qaoa import optimize_xy_qaoa

STOCK_TICKERS = ["PPLT", "GLD", "SLV", "AAPL", "MSFT", "NVDA", "JPM", "XOM"]
RISK_FACTOR = 0.5
SHOTS = 4096
OUT = Path("outputs/replication.json")


def _report(meta: dict, pairs: list[dict]) -> None:
    raw = [p["raw_hits"] for p in pairs]
    mit = [p["mit_hits"] for p in pairs]
    diff = [m - r for m, r in zip(mit, raw)]
    n = len(pairs)
    print(f"\n{'run':>4}{'raw':>7}{'mit':>7}{'diff':>7}   {'raw feas':>9}{'mit feas':>9}")
    for p, d in zip(pairs, diff):
        print(f"{p['run']:>4}{p['raw_hits']:>7}{p['mit_hits']:>7}{d:>+7}"
              f"   {p['raw_feasible']*100:>8.1f}%{p['mit_feasible']*100:>8.1f}%")
    print(f"\n  n = {n} pairs x {SHOTS} shots, backend {meta['backend']}")
    print(f"  raw        mean {sum(raw)/n:8.2f}   total {sum(raw)}")
    print(f"  mitigated  mean {sum(mit)/n:8.2f}   total {sum(mit)}")
    print(f"  mean difference {sum(diff)/n:+.2f}")

    nz = [d for d in diff if d != 0]
    if n >= 6 and nz:
        stat, p = wilcoxon(mit, raw)
        verdict = "replicates" if p < 0.05 else "does NOT replicate at alpha=0.05"
        print(f"\n  PAIRED Wilcoxon signed-rank: W = {stat:.1f}, p = {p:.5f}  ->  {verdict}")
        print("    The test that answers the question: it uses the within-pair")
        print("    difference, so between-run calibration drift cancels.")
    else:
        print(f"\n  Only {len(nz)} non-zero differences over {n} pairs — too few for a")
        print("    paired test. Report descriptively, do not compute a p-value.")

    tot_r, tot_m = sum(raw), sum(mit)
    _, pf = fisher_exact([[tot_r, n * SHOTS - tot_r], [tot_m, n * SHOTS - tot_m]])
    print(f"\n  Pooled Fisher exact: p = {pf:.6f}")
    print("    SHOWN FOR CONTRAST, NOT AS THE RESULT. Pooling throws away the")
    print("    pairing and treats correlated runs as one sample, inflating")
    print("    significance. The Wilcoxon figure above is the honest one.")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=10,
                    help="independent raw/mitigated PAIRS (default 10)")
    ap.add_argument("--backend", default="ibm_marrakesh",
                    help="QPU name. ibm_fez matches the shipped stocks result but "
                         "is usually deeply queued; ibm_marrakesh separates "
                         "backend from universe as the explanation for the "
                         "fez/marrakesh discrepancy.")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--budget", type=int, default=3)
    ap.add_argument("--resume", action="store_true",
                    help="continue an interrupted run from outputs/replication.json")
    ap.add_argument("--report-only", action="store_true",
                    help="re-print the analysis from the existing artefact")
    args = ap.parse_args()

    if args.report_only:
        d = json.loads(OUT.read_text())
        _report(d, d["pairs"])
        return 0

    print("Fetching stock market data...")
    market = get_market_data(STOCK_TICKERS, period="2y")
    problem = build_problem(market, budget=args.budget, risk_factor=RISK_FACTOR)
    exact = solve_exact(problem)
    n, k = problem.num_assets, args.budget
    print(f"  optimal: {[market.tickers[i] for i in exact.selection]} "
          f"obj={exact.objective:.4f}")
    print(f"  uniform-over-feasible null: 1/C({n},{k}) = {1/math.comb(n,k):.5f}\n")

    # Tune ONCE — see module docstring.
    print(f"Tuning XY-ring QAOA(reps={args.reps}) on simulator...")
    t0 = time.perf_counter()
    bound, _params, energy = optimize_xy_qaoa(problem, reps=args.reps, topology="ring")
    print(f"  tuned in {time.perf_counter()-t0:.1f}s   energy {energy:.6f}\n")

    svc = get_service()
    backend = svc.backend(args.backend)
    print(f"Backend {backend.name}: {backend.num_qubits} qubits, "
          f"{backend.status().pending_jobs} jobs queued\n")

    pairs: list[dict] = []
    if args.resume and OUT.exists():
        pairs = json.loads(OUT.read_text())["pairs"]
        print(f"Resuming: {len(pairs)} pairs already recorded\n")

    meta = {"backend": backend.name, "shots": SHOTS, "reps": args.reps,
            "mixer": "xy", "xy_topology": "ring", "universe": "stocks",
            "tickers": list(market.tickers), "budget": args.budget,
            "optimal_selection": exact.selection,
            "optimal_objective": exact.objective,
            "risk_factor": RISK_FACTOR,
            "mu": [float(x) for x in market.mu],
            "sigma": [[float(x) for x in row] for row in market.sigma]}

    for i in range(len(pairs), args.runs):
        # ALTERNATE the within-pair order. Always submitting raw first leaves a
        # systematic order effect: the two jobs are ~12s apart, so any drift
        # inside that window loads entirely onto one arm. Alternating makes the
        # order term cancel across pairs. arXiv:2605.29872 lists interleaving
        # as a requirement for QEM benchmarks, alongside paired designs and
        # modelling drift separately from shot noise.
        raw_first = (i % 2 == 0)
        print(f"--- pair {i+1}/{args.runs}  "
              f"({'raw first' if raw_first else 'mitigated first'}) ---")
        t0 = time.perf_counter()
        if raw_first:
            raw = sample_hardware(problem, bound, {}, exact.selection, backend,
                                  mitigate=False, shots=SHOTS)
            mit = sample_hardware(problem, bound, {}, exact.selection, backend,
                                  mitigate=True, shots=SHOTS)
        else:
            mit = sample_hardware(problem, bound, {}, exact.selection, backend,
                                  mitigate=True, shots=SHOTS)
            raw = sample_hardware(problem, bound, {}, exact.selection, backend,
                                  mitigate=False, shots=SHOTS)
        rh, mh = round(raw.p_optimal * SHOTS), round(mit.p_optimal * SHOTS)
        print(f"  raw {rh:>4}   mitigated {mh:>4}   diff {mh-rh:+d}"
              f"   ({time.perf_counter()-t0:.0f}s)")
        pairs.append({
            "run": i + 1,
            "raw_hits": rh, "mit_hits": mh, "shots": SHOTS,
            "raw_job_id": raw.job_id, "mit_job_id": mit.job_id,
            "raw_feasible": raw.feasible_fraction,
            "mit_feasible": mit.feasible_fraction,
            "raw_first": raw_first,
            "raw_counts": raw.counts, "mit_counts": mit.counts,
        })
        # Persist after EVERY pair. QPU queues are long; a crash at pair 9 must
        # not discard nine runs of data that cost real queue time.
        OUT.parent.mkdir(exist_ok=True)
        OUT.write_text(json.dumps({**meta, "pairs": pairs}, indent=2))

    _report(meta, pairs)
    print(f"\nWrote {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
