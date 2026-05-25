"""Market data: fetch real prices and derive the inputs the QUBO needs.

Expected returns (mu) and the covariance matrix (sigma) are the two ingredients
of mean-variance portfolio optimization. We annualize from daily data.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd
import yfinance as yf

TRADING_DAYS = 252


@dataclass
class MarketData:
    tickers: list[str]
    mu: np.ndarray          # annualized expected return per asset
    sigma: np.ndarray       # annualized covariance matrix
    prices: pd.DataFrame     # adjusted close history
    source: str             # "yfinance" or "synthetic"


def _close_frame(raw: pd.DataFrame, tickers: list[str]) -> pd.DataFrame:
    # yfinance returns a column MultiIndex like ("Close", "AAPL") for multi-ticker
    if isinstance(raw.columns, pd.MultiIndex):
        close = raw["Close"]
    else:
        close = raw[["Close"]]
        close.columns = tickers
    return close.dropna(how="all").ffill().dropna()


def get_market_data(tickers: list[str], period: str = "2y") -> MarketData:
    """Fetch real prices; fall back to a reproducible synthetic set if offline."""
    try:
        raw = yf.download(tickers, period=period, progress=False, auto_adjust=True)
        prices = _close_frame(raw, tickers)[tickers]
        if len(prices) < 30:
            raise ValueError("insufficient price history")
        daily = prices.pct_change().dropna()
        mu = daily.mean().to_numpy() * TRADING_DAYS
        sigma = daily.cov().to_numpy() * TRADING_DAYS
        return MarketData(tickers, mu, sigma, prices, "yfinance")
    except Exception as exc:  # offline / rate-limited: deterministic fallback
        print(f"[data] live fetch failed ({exc!s}); using synthetic data")
        return _synthetic(tickers)


def _synthetic(tickers: list[str], seed: int = 7) -> MarketData:
    n = len(tickers)
    rng = np.random.default_rng(seed)
    mu = 0.04 + 0.18 * rng.random(n)
    a = rng.standard_normal((n, n))
    cov = (a @ a.T) / n
    vol = (0.12 + 0.25 * rng.random(n))
    d = np.diag(vol)
    sigma = d @ (cov / np.sqrt(np.outer(np.diag(cov), np.diag(cov)))) @ d
    idx = pd.date_range("2024-01-01", periods=2, freq="D")
    prices = pd.DataFrame(np.ones((2, n)), columns=tickers, index=idx)
    return MarketData(tickers, mu, sigma, prices, "synthetic")
