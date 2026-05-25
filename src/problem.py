"""Build the portfolio optimization problem as a QUBO.

Binary mean-variance selection: choose `budget` of N assets to maximize
expected return minus risk_factor * variance. qiskit-finance maps this to a
QuadraticProgram, which becomes an Ising Hamiltonian for the quantum solvers.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from qiskit_finance.applications.optimization import PortfolioOptimization
from qiskit_optimization import QuadraticProgram

from .data import MarketData


@dataclass
class PortfolioProblem:
    app: PortfolioOptimization
    qp: QuadraticProgram
    tickers: list[str]
    budget: int
    risk_factor: float

    @property
    def num_assets(self) -> int:
        return len(self.tickers)

    def interpret(self, result) -> list[int]:
        """Return selected asset indices from an optimizer result."""
        return [int(i) for i in self.app.interpret(result)]


def build_problem(
    market: MarketData, budget: int, risk_factor: float = 0.5
) -> PortfolioProblem:
    if not 1 <= budget <= len(market.tickers):
        raise ValueError("budget must be between 1 and the number of assets")
    app = PortfolioOptimization(
        expected_returns=market.mu,
        covariances=market.sigma,
        risk_factor=risk_factor,
        budget=budget,
    )
    qp = app.to_quadratic_program()
    return PortfolioProblem(app, qp, market.tickers, budget, risk_factor)
