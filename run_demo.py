"""End-to-end demo: classical exact vs QAOA simulator on a real-data portfolio.

    python run_demo.py

Hardware + error-mitigation + AI forecasting layers are added in later milestones.
"""
from __future__ import annotations

from src.data import get_market_data
from src.problem import build_problem
from src.solvers import portfolio_metrics, solve_exact, solve_qaoa_sim

# A multi-asset universe spanning commodities (incl. platinum), equities, energy.
TICKERS = ["PPLT", "GLD", "SLV", "AAPL", "MSFT", "NVDA", "JPM", "XOM"]
BUDGET = 3
RISK_FACTOR = 0.5


def _fmt_selection(tickers: list[str], sel: list[int]) -> str:
    return ", ".join(tickers[i] for i in sel) if sel else "(none)"


def main() -> None:
    print("Fetching market data...")
    market = get_market_data(TICKERS, period="2y")
    print(f"  source: {market.source}  assets: {len(market.tickers)}")

    problem = build_problem(market, budget=BUDGET, risk_factor=RISK_FACTOR)
    print(f"  problem: choose {BUDGET} of {problem.num_assets} "
          f"(risk_factor={RISK_FACTOR})\n")

    results = [solve_exact(problem), solve_qaoa_sim(problem)]

    print(f"{'Method':<28}{'Selection':<22}{'Objective':>11}{'Time(s)':>9}")
    print("-" * 70)
    for r in results:
        print(f"{r.method:<28}{_fmt_selection(market.tickers, r.selection):<22}"
              f"{r.objective:>11.4f}{r.runtime_s:>9.3f}")

    exact, qaoa = results
    print("\nPortfolio metrics (annualized, equal-weight):")
    for r in results:
        m = portfolio_metrics(problem, market.mu, market.sigma, r.selection)
        print(f"  {r.method:<28} return={m['return']:+.2%}  "
              f"vol={m['volatility']:.2%}  sharpe={m['sharpe']:.2f}")

    print("\nResult:", "QAOA matched the exact optimum"
          if qaoa.matches(exact) else "QAOA found a different (sub)optimum")
    print("\nNote: at this scale the classical solver is provably optimal and "
          "faster.\nThe quantum value is the hybrid architecture and "
          "hardware-readiness,\ndemonstrated on real IBM QPUs in the next milestone.")


if __name__ == "__main__":
    main()
