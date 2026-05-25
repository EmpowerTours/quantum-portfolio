"""Run the walk-forward backtest and save equity-curve chart + metrics."""
from __future__ import annotations

import json
from pathlib import Path

import matplotlib.pyplot as plt

from src.backtest import run_backtest
from src.data import get_market_data

TICKERS = ["PPLT", "GLD", "SLV", "AAPL", "MSFT", "NVDA", "JPM", "XOM"]
BUDGET = 3
RISK_FACTOR = 0.5


def main() -> None:
    print("Fetching 5y of market data...")
    market = get_market_data(TICKERS, period="5y")
    print(f"  source: {market.source}  rows: {market.prices.shape[0]}\n")

    print("Running walk-forward backtest with AI forecasts...")
    res = run_backtest(market, budget=BUDGET, risk_factor=RISK_FACTOR,
                       warmup="1y", use_ai=True)

    print("\nMetrics:")
    for strat, m in res.metrics.items():
        print(f"  {strat:<35}  total={m['total_return']:+.2%}  "
              f"ann={m['ann_return']:+.2%}  vol={m['ann_vol']:.2%}  "
              f"sharpe={m['sharpe']:+.2f}  maxDD={m['max_drawdown']:.2%}")

    fig, ax = plt.subplots(figsize=(10, 5.5))
    colors = ["#1f77b4", "#7f7f7f"]
    for (col, series), color in zip(res.equity.items(), colors):
        ax.plot(series.index, series.values, label=col, color=color, linewidth=2)
    ax.set_title("Walk-forward backtest: quantum-AI portfolio vs equal-weight benchmark")
    ax.set_ylabel("Cumulative growth (start = 1.0)")
    ax.legend(loc="upper left")
    ax.spines[["top", "right"]].set_visible(False)
    ax.grid(alpha=0.3)
    plt.tight_layout()
    Path("outputs").mkdir(exist_ok=True)
    plt.savefig("outputs/backtest_equity.png", dpi=140)

    out = {
        "tickers": TICKERS, "budget": BUDGET, "risk_factor": RISK_FACTOR,
        "metrics": res.metrics,
        "n_rebalances": len(res.selections),
    }
    Path("outputs/backtest.json").write_text(json.dumps(out, indent=2))
    print("\nSaved outputs/backtest_equity.png and outputs/backtest.json")


if __name__ == "__main__":
    main()
