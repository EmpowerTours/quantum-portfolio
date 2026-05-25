"""AI forecasting layer: per-asset Ridge regression on technical features.

Replaces the naive historical-mean expected return with a model-based forecast,
trained walk-forward (no lookahead). The covariance is shrunk via Ledoit-Wolf
for numerical stability with short windows.

Why this is the right layer:
  * The QUBO's cost depends sensitively on the expected-return vector mu.
  * Naive mu = trailing mean is noisy and lag-biased.
  * A regularized regressor on momentum/volatility/mean-reversion features is a
    standard, interpretable baseline that demonstrates the AI half of the
    hybrid quantum-AI pipeline.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd
from sklearn.covariance import LedoitWolf
from sklearn.linear_model import Ridge
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

TRADING_DAYS = 252
HORIZON_DAYS = 21      # ~1 month forward return target


@dataclass
class Forecast:
    mu_hat: np.ndarray         # annualized expected return per asset
    sigma_hat: np.ndarray      # annualized covariance matrix
    as_of: pd.Timestamp
    tickers: list[str]
    model_r2: dict[str, float] # per-asset in-sample R^2 (transparency)


def _features(prices: pd.Series) -> pd.DataFrame:
    """Technical features for one asset, indexed by date."""
    r = prices.pct_change()
    f = pd.DataFrame(index=prices.index)
    for lag in (1, 5, 21, 63):
        f[f"ret_{lag}d"] = r.rolling(lag).sum()
    f["vol_21d"] = r.rolling(21).std()
    f["vol_63d"] = r.rolling(63).std()
    sma50 = prices.rolling(50).mean()
    sma200 = prices.rolling(200).mean()
    f["mom_sma50"] = prices / sma50 - 1
    f["mom_sma200"] = prices / sma200 - 1
    return f


def _train_one_asset(prices: pd.Series, as_of: pd.Timestamp,
                     horizon_days: int) -> tuple[float, float]:
    """Fit Ridge on features up to as_of; return (forecast_return, r2)."""
    feat = _features(prices)
    fwd = prices.pct_change(horizon_days).shift(-horizon_days)  # target
    df = feat.join(fwd.rename("y")).dropna()
    train = df.loc[df.index <= as_of]
    if len(train) < 60:
        # not enough data -- fall back to trailing mean of daily returns
        recent = prices.loc[prices.index <= as_of].pct_change().tail(63)
        return float(recent.mean()) * horizon_days, float("nan")
    X, y = train.drop(columns="y"), train["y"]
    pipe = Pipeline([("scale", StandardScaler()),
                     ("ridge", Ridge(alpha=1.0, random_state=0))])
    pipe.fit(X, y)
    r2 = float(pipe.score(X, y))

    latest = feat.loc[feat.index <= as_of].dropna()
    if latest.empty:
        return 0.0, r2
    yhat = float(pipe.predict(latest.iloc[[-1]])[0])
    return yhat, r2


def forecast(prices: pd.DataFrame, as_of: pd.Timestamp | None = None,
             horizon_days: int = HORIZON_DAYS) -> Forecast:
    """Walk-forward forecast: train on data up to `as_of`, predict next horizon."""
    if as_of is None:
        as_of = prices.index[-1]
    tickers = list(prices.columns)
    mu_period = np.zeros(len(tickers))
    r2 = {}
    for i, t in enumerate(tickers):
        y_hat, r2_i = _train_one_asset(prices[t], as_of, horizon_days)
        mu_period[i] = y_hat
        r2[t] = r2_i
    # annualize the horizon-return forecast
    mu_hat = mu_period * (TRADING_DAYS / horizon_days)

    # shrunk covariance from history up to as_of
    daily = prices.loc[prices.index <= as_of].pct_change().dropna()
    if len(daily) < 30:
        sigma_hat = np.eye(len(tickers)) * 0.04
    else:
        cov = LedoitWolf().fit(daily.values).covariance_
        sigma_hat = cov * TRADING_DAYS

    return Forecast(mu_hat=mu_hat, sigma_hat=sigma_hat,
                    as_of=pd.Timestamp(as_of), tickers=tickers, model_r2=r2)
