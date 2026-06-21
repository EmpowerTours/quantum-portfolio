"""Walk-forward backtester.

For each month-end, refit the AI forecaster on data up to that day (no
lookahead), solve the QUBO for the budget-constrained selection, and hold
equal-weight in the chosen assets for the next month. Compare strategies to a
plain equal-weight buy-and-hold benchmark on the full universe.

Honest framing: at MVP scale we solve the QUBO classically (fast and exact);
in production this is the step that runs on the QPU. The backtest demonstrates
the *pipeline*, not a proven alpha -- guard against over-interpreting any
single equity curve.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd

from .ai_forecast import TRADING_DAYS, forecast
from .data import MarketData
from .problem import build_problem
from .solvers import solve_exact


@dataclass
class BacktestResult:
    equity: pd.DataFrame                     # daily equity curve per strategy
    daily_returns: pd.DataFrame
    selections: dict                          # date -> list[asset_index]
    metrics: dict                             # strategy -> dict of metrics


def _metrics(daily: pd.Series) -> dict:
    if len(daily) == 0:
        return {"total_return": 0.0, "ann_return": 0.0, "ann_vol": 0.0,
                "sharpe": 0.0, "max_drawdown": 0.0}
    eq = (1 + daily).cumprod()
    total = float(eq.iloc[-1] - 1)
    years = max(len(daily) / TRADING_DAYS, 1 / TRADING_DAYS)
    ann_ret = float((1 + total) ** (1 / years) - 1)
    ann_vol = float(daily.std() * np.sqrt(TRADING_DAYS))
    sharpe = ann_ret / ann_vol if ann_vol > 0 else 0.0
    roll_max = eq.cummax()
    dd = (eq / roll_max - 1).min()
    return {"total_return": total, "ann_return": ann_ret, "ann_vol": ann_vol,
            "sharpe": float(sharpe), "max_drawdown": float(dd)}


def run_backtest(market: MarketData, budget: int = 3, risk_factor: float = 0.5,
                 warmup: str = "180d", use_ai: bool = True) -> BacktestResult:
    prices = market.prices
    tickers = list(prices.columns)
    n = len(tickers)

    if warmup.endswith("d") and warmup[:-1].isdigit():
        warmup_offset = pd.Timedelta(days=int(warmup[:-1]))
    elif warmup.endswith("y") and warmup[:-1].isdigit():
        warmup_offset = pd.DateOffset(years=int(warmup[:-1]))
    else:
        raise ValueError("warmup must use a value such as '90d', '180d', or '1y'")

    start = prices.index.min() + warmup_offset
    rebal_idx = prices.resample("ME").last().index
    rebal_idx = rebal_idx[rebal_idx >= start]
    if len(rebal_idx) < 2:
        history_days = max(0, (prices.index.max() - prices.index.min()).days)
        raise ValueError(
            f"{warmup} warmup leaves no complete monthly holding period "
            f"in the available {history_days}-day history"
        )

    selections, daily_strat, daily_equal, dates = {}, [], [], []

    for i, d in enumerate(rebal_idx[:-1]):
        next_d = rebal_idx[i + 1]
        if use_ai:
            f = forecast(prices.loc[:d], as_of=d)
            mu, sigma = f.mu_hat, f.sigma_hat
        else:
            daily = prices.loc[:d].pct_change().dropna()
            if len(daily) < 30: continue
            mu = daily.mean().values * TRADING_DAYS
            sigma = daily.cov().values * TRADING_DAYS

        m = MarketData(tickers, mu, sigma, prices, "in-sample")
        problem = build_problem(m, budget=budget, risk_factor=risk_factor)
        sel = solve_exact(problem).selection
        selections[d] = sel

        window = prices.loc[d:next_d]
        if len(window) < 2: continue
        rets = window.pct_change().dropna()
        w = np.zeros(n); w[sel] = 1.0 / len(sel)
        daily_strat.append(pd.Series(rets.values @ w, index=rets.index))
        daily_equal.append(rets.mean(axis=1))

    if not daily_strat:
        raise RuntimeError("backtest produced no periods; check warmup vs history")

    strat = pd.concat(daily_strat); equal = pd.concat(daily_equal)
    daily_rets = pd.DataFrame({
        ("Quantum-AI rebalanced" if use_ai else "Quantum rebalanced (historical mu)"): strat,
        "Equal-weight buy & hold": equal,
    }).dropna(how="all").fillna(0.0)
    equity = (1 + daily_rets).cumprod()

    metrics = {c: _metrics(daily_rets[c]) for c in daily_rets.columns}
    return BacktestResult(equity=equity, daily_returns=daily_rets,
                          selections=selections, metrics=metrics)
