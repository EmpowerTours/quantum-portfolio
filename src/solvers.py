"""Solvers: exact classical baseline and QAOA on a noiseless simulator.

Each returns a uniform SolveResult so the benchmark can compare them directly.
Hardware + error-mitigated runs live in hardware.py (added next milestone).
"""
from __future__ import annotations

import time
from dataclasses import dataclass

import numpy as np
from qiskit.primitives import StatevectorSampler
from qiskit_algorithms import QAOA, NumPyMinimumEigensolver
from qiskit_algorithms.optimizers import COBYLA
from qiskit_optimization.algorithms import MinimumEigenOptimizer

from .problem import PortfolioProblem


@dataclass
class SolveResult:
    method: str
    selection: list[int]      # chosen asset indices
    objective: float          # QUBO objective value (lower is better)
    runtime_s: float

    def matches(self, other: "SolveResult") -> bool:
        return set(self.selection) == set(other.selection)


def solve_exact(problem: PortfolioProblem) -> SolveResult:
    """Provably optimal classical baseline (brute-force eigensolver)."""
    t0 = time.perf_counter()
    opt = MinimumEigenOptimizer(NumPyMinimumEigensolver())
    res = opt.solve(problem.qp)
    return SolveResult(
        "Classical (exact)",
        problem.interpret(res),
        float(res.fval),
        time.perf_counter() - t0,
    )


def solve_qaoa_sim(
    problem: PortfolioProblem, reps: int = 2, maxiter: int = 100, seed: int = 42
) -> SolveResult:
    """QAOA on an ideal (noiseless) statevector simulator."""
    t0 = time.perf_counter()
    sampler = StatevectorSampler(seed=seed)
    qaoa = QAOA(sampler=sampler, optimizer=COBYLA(maxiter=maxiter), reps=reps)
    opt = MinimumEigenOptimizer(qaoa)
    res = opt.solve(problem.qp)
    return SolveResult(
        f"QAOA (simulator, reps={reps})",
        problem.interpret(res),
        float(res.fval),
        time.perf_counter() - t0,
    )


def portfolio_metrics(problem: PortfolioProblem, mu: np.ndarray, sigma: np.ndarray,
                      selection: list[int]) -> dict:
    """Equal-weight return/volatility for a chosen asset subset."""
    if not selection:
        return {"return": 0.0, "volatility": 0.0, "sharpe": 0.0}
    w = np.zeros(len(mu))
    w[selection] = 1.0 / len(selection)
    ret = float(w @ mu)
    var = float(w @ sigma @ w)
    vol = float(np.sqrt(max(var, 0.0)))
    return {"return": ret, "volatility": vol, "sharpe": ret / vol if vol else 0.0}
