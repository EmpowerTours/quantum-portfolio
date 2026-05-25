"""Constraint-preserving QAOA (Quantum Alternating Operator Ansatz).

A standard QAOA mixer (transverse field) leaks amplitude into states that
violate the budget (wrong number of assets), so very little probability lands
on the optimal portfolio. We instead use:

  * an initial state of Hamming weight = budget (a feasible basis state), and
  * an XY ring mixer exp(-i b (XX+YY)) per edge, which conserves Hamming weight.

Together these keep the entire search inside the "exactly `budget` assets"
subspace. No penalty term is needed, so the cost Hamiltonian is the bare
portfolio objective. This dramatically raises P(optimal) -- essential for a
clean signal on noisy hardware.
"""
from __future__ import annotations

import numpy as np
from qiskit import QuantumCircuit
from qiskit.circuit import ParameterVector
from qiskit_optimization import QuadraticProgram

from .problem import PortfolioProblem


def objective_hamiltonian(problem: PortfolioProblem):
    """Ising operator for the portfolio objective ONLY (no budget penalty)."""
    src = problem.qp.objective
    qp = QuadraticProgram()
    for v in problem.qp.variables:        # preserve the original "x_0..x_n" names
        qp.binary_var(name=v.name)
    qp.minimize(
        constant=src.constant,
        linear=src.linear.to_dict(use_name=True),
        quadratic=src.quadratic.to_dict(use_name=True),
    )
    return qp.to_ising()  # (SparsePauliOp, offset)


def _apply_cost_layer(qc: QuantumCircuit, hamiltonian, gamma, scale: float = 1.0) -> None:
    n = qc.num_qubits
    for pauli, coeff in zip(hamiltonian.paulis, hamiltonian.coeffs):
        c = float(np.real(coeff)) * scale
        label = pauli.to_label()          # index 0 = highest qubit
        zpos = [n - 1 - i for i, ch in enumerate(label) if ch == "Z"]
        if len(zpos) == 1:
            qc.rz(2 * gamma * c, zpos[0])
        elif len(zpos) == 2:
            qc.rzz(2 * gamma * c, zpos[0], zpos[1])
        # identity term -> global phase, ignored


def _hamiltonian_scale(hamiltonian) -> float:
    """1 / max(|coeff|) over non-identity Pauli terms.

    Portfolio objective coefficients are O(0.01-0.05) annualized, so without
    rescaling gamma in [0, pi] barely rotates the cost layer and the optimizer
    sees a near-flat landscape. Normalizing makes [0, pi] a meaningful range.
    """
    max_c = 0.0
    for pauli, coeff in zip(hamiltonian.paulis, hamiltonian.coeffs):
        if "Z" in pauli.to_label():
            max_c = max(max_c, abs(float(np.real(coeff))))
    return 1.0 / max_c if max_c > 0 else 1.0


def _xy_edges(n: int, topology: str) -> list[tuple[int, int]]:
    if topology == "ring":
        return [(i, (i + 1) % n) for i in range(n)] if n > 2 else [(0, 1)]
    if topology == "complete":   # every pair -- more expressive, more gates
        return [(i, j) for i in range(n) for j in range(i + 1, n)]
    raise ValueError(f"unknown topology: {topology}")


def _apply_xy_mixer(qc: QuantumCircuit, beta, topology: str = "complete") -> None:
    for i, j in _xy_edges(qc.num_qubits, topology):
        qc.rxx(2 * beta, i, j)
        qc.ryy(2 * beta, i, j)


def build_xy_qaoa(problem: PortfolioProblem, reps: int = 2, normalize: bool = True):
    """Return (parameterized circuit, cost Hamiltonian, offset, scale).

    `scale` is the multiplier baked into the cost layer (1.0 if not normalized).
    """
    hamiltonian, offset = objective_hamiltonian(problem)
    scale = _hamiltonian_scale(hamiltonian) if normalize else 1.0
    n, k = problem.num_assets, problem.budget
    qc = QuantumCircuit(n)
    for i in range(k):                     # feasible init: |1..1 0..0> weight k
        qc.x(i)
    gammas = ParameterVector("g", reps)
    betas = ParameterVector("b", reps)
    for r in range(reps):
        _apply_cost_layer(qc, hamiltonian, gammas[r], scale=scale)
        _apply_xy_mixer(qc, betas[r], topology="complete")
    return qc, hamiltonian, offset, scale


def optimize_xy_qaoa(problem: PortfolioProblem, reps: int = 3,
                     n_restarts: int = 12, maxiter: int = 200, seed: int = 42):
    """Tune XY-mixer QAOA angles on a noiseless simulator.

    Uses TQA (Trotterized Quantum Annealing) warm starts at several dt scales,
    plus random restarts. Returns (bound_circuit, optimal_params_dict, min_value).
    """
    from qiskit.primitives import StatevectorEstimator
    from scipy.optimize import minimize

    qc, H, _, _ = build_xy_qaoa(problem, reps=reps, normalize=True)
    est = StatevectorEstimator(seed=seed)
    order = list(qc.parameters)

    def cost(x: np.ndarray) -> float:
        bound = qc.assign_parameters(dict(zip(order, x)))
        return float(est.run([(bound, H)]).result()[0].data.evs)

    beta_idx, gamma_idx = {}, {}
    for i, p in enumerate(order):
        name = p.name
        idx = int(name.split("[")[1].rstrip("]"))
        (beta_idx if name.startswith("b") else gamma_idx)[idx] = i

    def tqa_init(dt: float) -> np.ndarray:
        x0 = np.zeros(len(order))
        for r in range(reps):
            x0[gamma_idx[r]] = (r + 1) / (reps + 1) * dt
            x0[beta_idx[r]] = (1 - (r + 1) / (reps + 1)) * dt
        return x0

    rng = np.random.default_rng(seed)
    starts = [tqa_init(dt) for dt in (0.4, 0.7, 1.0, 1.3, 1.7)]
    while len(starts) < n_restarts:
        starts.append(rng.uniform(0, np.pi, len(order)))

    best_x, best_f = None, float("inf")
    for x0 in starts:
        res = minimize(cost, x0, method="COBYLA",
                       options={"maxiter": maxiter, "rhobeg": 0.3})
        if res.fun < best_f:
            best_f, best_x = float(res.fun), res.x

    bound = qc.assign_parameters(dict(zip(order, best_x)))
    return bound, dict(zip([p.name for p in order], best_x)), best_f
