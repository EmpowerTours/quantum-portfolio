"""CVaR tuning must raise P(optimal), and must not disturb the default.

Tuned on <H>, this circuit's most-likely feasible state is the 7th-best
portfolio of 56 on a NOISELESS simulator. That is NOT a wrong shipped answer —
`_score_counts` decodes best-of-N over sampled feasible states, not the mode —
but it is a low P(optimal), which is the metric the hardware arms are scored on
and what decides whether a run clears the uniform-over-feasible null. These
tests pin both halves: that CVaR nearly doubles P(optimal) and moves the mode
onto the optimum, and that the shipped "mean" path is unchanged so existing
hardware artefacts still reproduce.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import pandas as pd
import pytest
from qiskit.quantum_info import Statevector

from src.data import MarketData
from src.problem import build_problem
from src.solvers import solve_exact
from src.xy_qaoa import _basis_energies, _cvar, optimize_xy_qaoa

ARTEFACT = Path("outputs/replication_marrakesh_interleaved.json")
REPS = 3


@pytest.fixture(scope="module")
def problem():
    """The exact instance quoted in the optimiser docstring."""
    if not ARTEFACT.exists():
        pytest.skip(f"{ARTEFACT} not present")
    d = json.loads(ARTEFACT.read_text())
    market = MarketData(
        tickers=list(d["tickers"]),
        mu=np.array(d["mu"]),
        sigma=np.array(d["sigma"]),
        prices=pd.DataFrame(),
        source="replay",
    )
    return build_problem(market, budget=d["budget"], risk_factor=d["risk_factor"])


@pytest.fixture(scope="module")
def tuned(problem):
    """Memoised tuner. Each call is ~20s of statevector optimisation and the
    tests below reuse the same handful of (objective, alpha, seed) points, so
    without this the module spends most of its time re-deriving angles it has
    already derived."""
    cache: dict = {}

    def get(objective: str = "mean", alpha: float = 0.5, seed: int = 42):
        key = (objective, alpha, seed)
        if key not in cache:
            cache[key] = optimize_xy_qaoa(problem, reps=REPS, topology="ring",
                                          objective=objective, alpha=alpha,
                                          seed=seed)
        return cache[key]

    return get


@pytest.fixture(scope="module")
def optimum(problem):
    return tuple(sorted(solve_exact(problem).selection))


def _modal_feasible(problem, bound):
    """The answer standard QAOA decoding returns: most-likely feasible state."""
    energies, feasible = _basis_energies(problem)
    probs = np.abs(Statevector(bound).data) ** 2
    idx = int(np.argmax(probs * feasible))
    n = problem.num_assets
    sel = tuple(i for i in range(n) if (idx >> i) & 1)
    return sel, float(probs[idx])


def _p_optimal(problem, bound, optimal):
    probs = np.abs(Statevector(bound).data) ** 2
    return float(probs[sum(1 << i for i in optimal)])


def test_mean_tuning_modal_state_is_suboptimal(problem, tuned, optimum):
    """The baseline, pinned. If the mean-tuned mode ever lands on the optimum,
    the baseline changed and the CVaR comparison below needs re-deriving."""
    modal, _ = _modal_feasible(problem, tuned()[0])
    assert modal != optimum, "baseline unexpectedly correct — re-derive the docstring table"


def test_cvar_tuning_returns_the_optimal_portfolio(problem, tuned, optimum):
    modal, _ = _modal_feasible(problem, tuned("cvar", 0.5)[0])
    assert modal == optimum, f"CVaR should return the optimum, got {modal}"


def test_cvar_raises_p_optimal_over_mean(problem, tuned, optimum):
    p_mean = _p_optimal(problem, tuned()[0], optimum)
    p_cvar = _p_optimal(problem, tuned("cvar", 0.5)[0], optimum)
    assert p_cvar > p_mean, f"CVaR {p_cvar:.4f} did not beat mean {p_mean:.4f}"


@pytest.mark.parametrize("seed", [1, 2024])
def test_cvar_win_is_not_a_seed_artefact(problem, tuned, optimum, seed):
    """A result visible only at the default seed would be noise dressed as a
    finding. Swept over seeds 1/7/42/123/2024/31337 by hand: mean lands on the
    SAME rank-7 portfolio at every one, CVaR on the optimum at every one. Two
    off-default seeds are pinned here; the rest are too slow for CI."""
    mean_modal, _ = _modal_feasible(problem, tuned(seed=seed)[0])
    cvar_modal, _ = _modal_feasible(problem, tuned("cvar", 0.5, seed)[0])
    assert mean_modal != optimum, f"mean unexpectedly correct at seed {seed}"
    assert cvar_modal == optimum, f"CVaR missed the optimum at seed {seed}"


def test_cvar_preserves_feasibility(problem, tuned):
    """The XY mixer's guarantee must survive the objective change — a CVaR gain
    bought by leaking outside the budget subspace would not be a gain."""
    _, feasible = _basis_energies(problem)
    probs = np.abs(Statevector(tuned("cvar", 0.5)[0]).data) ** 2
    assert (probs * feasible).sum() == pytest.approx(1.0, abs=1e-9)


def test_default_objective_is_mean(problem):
    """Shipped hardware artefacts were tuned on <H>; the default must not move
    or they stop reproducing."""
    a = optimize_xy_qaoa(problem, reps=REPS, topology="ring")[2]
    b = optimize_xy_qaoa(problem, reps=REPS, topology="ring", objective="mean")[2]
    assert a == b


def test_cvar_helper_skips_zero_amplitude_states(problem):
    """Infeasible states have LOWER raw objective (no penalty term) and zero
    amplitude. Breaking on them instead of skipping returns before any mass is
    accumulated — this is the bug that made the first implementation divide by
    zero, and it would silently return garbage if it merely truncated."""
    energies, feasible = _basis_energies(problem)
    order = np.argsort(energies)
    probs = feasible / feasible.sum()          # uniform over feasible only
    assert energies[order[0]] < energies[: len(energies)][feasible].min()
    got = _cvar(probs, energies, order, 0.5)
    best_half = np.sort(energies[feasible])[: math.ceil(feasible.sum() / 2)]
    assert got == pytest.approx(best_half.mean(), rel=1e-6)


def test_cvar_alpha_one_equals_mean(problem):
    energies, feasible = _basis_energies(problem)
    order = np.argsort(energies)
    probs = feasible / feasible.sum()
    assert _cvar(probs, energies, order, 1.0) == pytest.approx(float(probs @ energies))


@pytest.mark.parametrize("bad", [0.0, -0.1, 1.5])
def test_invalid_alpha_rejected(problem, bad):
    with pytest.raises(ValueError, match="alpha"):
        optimize_xy_qaoa(problem, reps=1, topology="ring", objective="cvar", alpha=bad)


def test_unknown_objective_rejected(problem):
    with pytest.raises(ValueError, match="objective"):
        optimize_xy_qaoa(problem, reps=1, topology="ring", objective="median")
