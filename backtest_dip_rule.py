#!/usr/bin/env python3
"""Walk-forward backtest of a buy-the-dip / take-profit rule on MON.

Rule: if price is DOWN `dip`% over the last `lookback` hours and we are flat,
buy. Exit at +`target`% or after `timeout` hours, whichever comes first.

Costs are charged on BOTH legs and are deliberately realistic for the live
Monad venue:
  * 0.30 % Uniswap v3 pool fee (the WMON/USDC 0.3 % pool is the only one
    with real depth — measured 2026-07-30)
  * 0.05 % slippage assumption
  * ~0.0264 MON of gas per swap, expressed as a fraction of trade size

No lookahead: every decision at bar t uses only data up to and including t,
and fills happen at bar t's price.

The benchmark is buy-and-hold over the identical window, because a strategy
that makes money in a bull market has proved nothing.
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, UTC
from pathlib import Path

SERIES = Path("/tmp/claude-1000/-home-empowertours/01b4a520-b3a3-4e37-be2b-cb6e3952e2fa/scratchpad/mon_hourly.json")

POOL_FEE = 0.0030
SLIPPAGE = 0.0005
GAS_MON = 0.0264          # measured: anchor + executeAndRoute on Monad mainnet


def load():
    return [(int(t), float(p)) for t, p in json.loads(SERIES.read_text())]


def run(series, dip, lookback, target, timeout, trade_size_mon=100.0):
    """Return (net_return, n_trades, n_wins) for one parameter set."""
    prices = [p for _, p in series]
    n = len(prices)
    gas_frac = GAS_MON / trade_size_mon
    cost_per_leg = POOL_FEE + SLIPPAGE + gas_frac

    equity = 1.0
    i = lookback
    trades = wins = 0
    while i < n:
        past, now_p = prices[i - lookback], prices[i]
        if past > 0 and (now_p / past - 1.0) <= -dip:
            entry = now_p * (1 + cost_per_leg)          # pay to get in
            exit_i = min(i + timeout, n - 1)
            for j in range(i + 1, exit_i + 1):
                if prices[j] / now_p - 1.0 >= target:
                    exit_i = j
                    break
            exit_p = prices[exit_i] * (1 - cost_per_leg)  # pay to get out
            r = exit_p / entry
            equity *= r
            trades += 1
            wins += r > 1.0
            i = exit_i + 1
        else:
            i += 1
    return equity - 1.0, trades, wins


def buy_hold(series):
    return series[-1][1] / series[0][1] - 1.0


def main() -> int:
    series = load()
    d0 = datetime.fromtimestamp(series[0][0], UTC).date()
    d1 = datetime.fromtimestamp(series[-1][0], UTC).date()
    print(f"MON hourly, {len(series)} bars, {d0} -> {d1}")
    print(f"buy & hold over the whole window: {buy_hold(series)*100:+.1f} %")
    print(f"costs charged per leg: {(POOL_FEE+SLIPPAGE)*100:.2f} % + gas\n")

    grid = [(d, lb, tg, to)
            for d in (0.02, 0.03, 0.05)
            for lb in (24, 48)
            for tg in (0.03, 0.05, 0.08)
            for to in (48, 96)]

    print(f"{'dip':>5}{'look':>6}{'tgt':>6}{'tmo':>5}{'trades':>8}{'win%':>7}{'net':>9}{'vs B&H':>9}")
    print("-" * 56)
    rows = []
    bh = buy_hold(series)
    for d, lb, tg, to in grid:
        net, t, w = run(series, d, lb, tg, to)
        rows.append((net, d, lb, tg, to, t, w))
        print(f"{d*100:>4.0f}%{lb:>6}{tg*100:>5.0f}%{to:>5}{t:>8}"
              f"{(w/t*100 if t else 0):>6.0f}%{net*100:>8.1f}%{(net-bh)*100:>8.1f}%")

    rows.sort(reverse=True)
    print(f"\nbest: dip {rows[0][1]*100:.0f}% / look {rows[0][2]}h / "
          f"target {rows[0][3]*100:.0f}% / timeout {rows[0][4]}h "
          f"-> {rows[0][0]*100:+.1f} % ({rows[0][5]} trades)")
    print(f"{sum(1 for r in rows if r[0] > 0)}/{len(rows)} parameter sets profitable")
    print(f"{sum(1 for r in rows if r[0] > bh)}/{len(rows)} beat buy & hold")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
