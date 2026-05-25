"""DeFi yield-pool data via the public DeFiLlama API.

Replaces the Yahoo-Finance stock data layer with real DeFi pool yields.
Universe is curated: Monad-primary (where the agents execute) plus a few
high-TVL Ethereum stablecoin pools (where the EVM-compatible agents can
reach for breadth).

The optimizer math is identical to the stock pipeline:
  - "expected return" mu  = mean annualized APY of each pool (decimal)
  - "covariance" sigma    = annualized covariance of daily yield returns
  - "prices"              = cumulative wealth assuming you held each pool

So the same QUBO + QAOA + backtest pipeline plugs in unchanged.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd
import requests

from .data import MarketData

POOLS_URL = "https://yields.llama.fi/pools"
HISTORY_URL = "https://yields.llama.fi/chart/{pool_id}"
TRADING_DAYS = 365  # crypto/yield: continuous, use 365 not 252


# (project, symbol_match, chain, display_label)
CURATED_UNIVERSE: list[tuple[str, str, str, str]] = [
    ("morpho-blue", "STEAKETH",   "Monad",    "Morpho STEAKETH (Monad)"),
    ("upshift",     "EARNAUSD",   "Monad",    "Upshift earnAUSD (Monad)"),
    ("morpho-blue", "HYPERUSDCA", "Monad",    "Morpho hyperUSDC (Monad)"),
    ("neverland",   "USDC",       "Monad",    "Neverland USDC (Monad)"),
    ("shmonad",     "SHMON",      "Monad",    "shMONAD (Monad)"),
    ("sky-lending", "SUSDS",      "Ethereum", "Sky sUSDS (ETH)"),
    ("ethena-usde", "SUSDE",      "Ethereum", "Ethena sUSDe (ETH)"),
    ("maple",       "USDC",       "Ethereum", "Maple USDC (ETH)"),
]


@dataclass
class PoolMeta:
    pool_id: str
    project: str
    chain: str
    symbol: str
    label: str
    tvl_usd: float


def fetch_all_pools() -> list[dict]:
    r = requests.get(POOLS_URL, timeout=20)
    r.raise_for_status()
    return r.json()["data"]


def resolve_universe(spec: list[tuple[str, str, str, str]] = CURATED_UNIVERSE
                     ) -> list[PoolMeta]:
    pools = fetch_all_pools()
    resolved: list[PoolMeta] = []
    for project, sym, chain, label in spec:
        candidates = [p for p in pools
                      if p.get("project") == project
                      and p.get("chain") == chain
                      and sym in (p.get("symbol") or "")]
        if not candidates:
            print(f"[defi] warning: no pool matched {project}/{sym}/{chain}")
            continue
        best = max(candidates, key=lambda x: x.get("tvlUsd") or 0)
        resolved.append(PoolMeta(
            pool_id=best["pool"], project=best["project"], chain=best["chain"],
            symbol=best["symbol"], label=label,
            tvl_usd=float(best.get("tvlUsd") or 0),
        ))
    return resolved


def fetch_history(pool_id: str, days: int = 365) -> pd.DataFrame:
    r = requests.get(HISTORY_URL.format(pool_id=pool_id), timeout=20)
    r.raise_for_status()
    payload = r.json()
    rows = payload.get("data", [])
    df = pd.DataFrame(rows)
    df["timestamp"] = pd.to_datetime(df["timestamp"])
    df = df.set_index("timestamp").sort_index()
    if days:
        df = df[df.index >= df.index[-1] - pd.Timedelta(days=days)]
    return df[["apy"]].astype(float)


def get_defi_market_data(days: int = 365) -> MarketData:
    """Return MarketData built from real DeFi yield pools."""
    resolved = resolve_universe()
    apy_frames = {}
    for p in resolved:
        try:
            h = fetch_history(p.pool_id, days=days)
            if len(h) >= 30:
                apy_frames[p.label] = h["apy"]
            else:
                print(f"[defi] {p.label}: only {len(h)} days, skipping")
        except Exception as exc:
            print(f"[defi] {p.label}: history fetch failed ({exc!s})")

    if len(apy_frames) < 2:
        raise RuntimeError("fewer than 2 pools fetched; try again or "
                           "broaden the universe")

    apy_df = pd.DataFrame(apy_frames).sort_index()
    # daily granularity, forward/back-fill small gaps
    apy_df = apy_df.resample("D").last().ffill().bfill().dropna()

    # daily yield return (per day) = APY% / 100 / 365
    daily_ret = apy_df / 100.0 / TRADING_DAYS

    # cumulative wealth series acts as the "price" the rest of the pipeline expects
    wealth = (1 + daily_ret).cumprod() * 100.0

    # annualized expected return: mean APY (already annual, just in percent)
    mu = (apy_df.mean() / 100.0).values
    # annualized covariance of daily yield returns
    sigma = daily_ret.cov().values * TRADING_DAYS

    labels = list(apy_df.columns)
    return MarketData(tickers=labels, mu=mu, sigma=sigma, prices=wealth,
                      source="defillama")
