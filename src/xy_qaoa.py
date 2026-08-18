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


def build_xy_qaoa(problem: PortfolioProblem, reps: int = 2, normalize: bool = True,
                  topology: str = "ring"):
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
        _apply_xy_mixer(qc, betas[r], topology=topology)
    return qc, hamiltonian, offset, scale


def _basis_energies(problem: PortfolioProblem) -> tuple[np.ndarray, np.ndarray]:
    """Objective value and feasibility of every basis state.

    Indexed to match `Statevector`: bit i of the index is qubit i is asset i.
    """
    n, k = problem.num_assets, problem.budget
    energies = np.zeros(2 ** n)
    feasible = np.zeros(2 ** n, dtype=bool)
    for idx in range(2 ** n):
        bits = [(idx >> i) & 1 for i in range(n)]
        energies[idx] = problem.qp.objective.evaluate(bits)
        feasible[idx] = sum(bits) == k
    return energies, feasible


def _cvar(probs: np.ndarray, energies: np.ndarray, order: np.ndarray,
          alpha: float) -> float:
    """Exact CVaR_alpha: probability-weighted mean of the best `alpha` mass.

    Computed from the statevector rather than from samples, so the tuning
    landscape is deterministic and free of shot noise.
    """
    if alpha >= 1.0:
        return float(probs @ energies)
    acc = tot = 0.0
    for i in order:
        # The cost Hamiltonian carries NO budget penalty, so infeasible states
        # have lower raw objective than any feasible one and sort first — with
        # zero amplitude, because the XY mixer conserves Hamming weight.
        # Skipping is required; breaking would return before accumulating mass.
        if probs[i] <= 1e-15:
            continue
        take = min(probs[i], alpha - acc)
        tot += take * energies[i]
        acc += take
        if acc >= alpha:
            break
    return tot / acc if acc > 0 else float(probs @ energies)


def optimize_xy_qaoa(problem: PortfolioProblem, reps: int = 3,
                     n_restarts: int = 12, maxiter: int = 200, seed: int = 42,
                     topology: str = "ring", objective: str = "mean",
                     alpha: float = 0.5):
    """Tune XY-mixer QAOA angles on a noiseless simulator.

    `objective` selects what the classical optimiser minimises:

      "mean"  -- <H>, the textbook QAOA objective. DEFAULT, because every
                 shipped hardware artefact was tuned this way and must keep
                 reproducing bit-identically.
      "cvar"  -- CVaR_alpha, the mean of the best `alpha` probability mass
                 (Barkoutsos et al., Quantum 4, 256 (2020), arXiv:1907.04769).

    WHY CVaR EXISTS HERE. Minimising the MEAN is not the same as maximising
    P(optimal), and on this instance the gap is large: tuned on <H>, the
    circuit's most-likely feasible state is the 7th-best portfolio of 56 -- on
    a NOISELESS simulator, with no hardware noise involved. The docstring below
    already recorded the extreme form of this at reps=2 ("rotating
    deterministically onto a single suboptimal basis state") and worked around
    it by requiring reps >= 3; the pathology survives at reps=3, only milder.

    WHAT THIS DOES **NOT** MEAN. This pipeline does not decode modally.
    `_score_counts` in src/qaoa_hw.py scans every sampled feasible bitstring
    and keeps the lowest-objective one, so at 4096 shots a mean-tuned run still
    REPORTS the optimum -- the shipped artefacts are not wrong. The mode
    matters for textbook QAOA decoding, which does take the most-frequent
    bitstring and would return the rank-7 portfolio here. Do not read this as
    "the shipped runs answered the wrong question".

    What mean-tuning actually costs is P(optimal) itself, and that is not a
    cosmetic metric here: it is what the hardware arms are scored on, and what
    decides whether a run clears the uniform-over-feasible null of 1/C(8,3).
    Nearly doubling it on a NOISELESS simulator raises the ceiling every noisy
    arm is working under.

    CVaR targets the low-energy tail instead of the bulk, which is where the
    optimum lives. Measured on the marrakesh replication instance (8 assets,
    budget 3, ring, reps=3, exact statevector):

        <H>            P(opt) 0.1848   modal (0,5,6)  rank 7
        CVaR a=0.50    P(opt) 0.3155   modal (2,5,6)  OPTIMUM
        CVaR a=0.25    P(opt) 0.2500   modal (2,5,6)  OPTIMUM
        CVaR a=0.10    P(opt) 0.1036   modal (5,6,7)  rank 19
        CVaR a=0.05    P(opt) 0.0626   modal (5,6,7)  rank 19

    Feasibility stays 100% throughout (the XY mixer guarantees it) and the
    CIRCUIT IS UNCHANGED -- same gates, same depth, same 2Q count. The gain is
    free on hardware.

    ALPHA IS NOT MONOTONE, for the reason the paper gives: alpha "introduces a
    soft cap on the maximum probability of sampling a ground state ... because
    the CVaR objective function with alpha = 1% does not reward increasing the
    overlap with the ground state beyond 1% probability" (sec. 6). The table
    above lands on that cap almost exactly -- a=0.25 gives 0.2500, a=0.10 gives
    0.1036. The tail stops paying for overlap it already has.

    So 0.5 is the default even though the paper recommends alpha in [0.1, 0.25].
    That recommendation optimises convergence of the variational loop under a
    sampling-accuracy argument (CVaR needs ~1/alpha more samples for equal
    accuracy). This code optimises P(optimal) at a fixed shot count instead,
    and under the soft cap any alpha below ~0.32 caps the result beneath the
    0.3155 that alpha=0.5 reaches. Deliberate divergence, not an oversight.

    NOT A SEED ARTEFACT. Swept over seeds 1, 7, 42, 123, 2024, 31337: <H>
    lands on the SAME rank-7 portfolio (0,5,6) at all six, P(opt) 0.148-0.227;
    CVaR a=0.5 lands on the optimum (2,5,6) at all six, P(opt) 0.296-0.329. So
    mean-tuning does not merely happen to miss here -- it converges somewhere
    else. Seeds 1 and 2024 are pinned in tests/test_cvar_qaoa.py.

    IT DOES NOT REPLICATE ON A SECOND INSTANCE, AND IT REVERSES. On 2026-08-17
    a matched pair was run on ibm_marrakesh -- same tickers, budget 3, risk
    factor 0.5, reps=3 ring, same market window, minutes apart, objective the
    only difference. mean BEAT cvar on every column:

        mean        sim 0.2305   hw raw 0.0264   hw mitigated 0.0186
        cvar a=0.5  sim 0.1865   hw raw 0.0112   hw mitigated 0.0164

    (artefacts: outputs/hardware_run_mean_20260817.json and
    outputs/hardware_run_cvar0p5.json). The two instances differ only in the
    market-data window -- same tickers, same budget, same risk factor -- so the
    table above is a property of THAT instance, not of the objective.

    So: do NOT claim cvar improves P(optimal). Two instances, one each way. The
    default stays "mean", every shipped artefact is mean-tuned, and settling
    this needs a paired sweep across many windows rather than another anecdote.

    `topology` defaults to "ring" (n edges) rather than "complete" (n(n-1)/2).
    Measured on FakeMarrakesh with 8 assets, budget 3, simulator P(optimal)
    against a uniform-over-feasible null of 1/C(8,3) = 0.0179:

        complete reps=2   P(opt) 0.0000   2Q   ~0   (collapses to one state)
        complete reps=6   P(opt) 0.0808   2Q 1572
        ring     reps=3   P(opt) 0.2078   2Q  454
        ring     reps=4   P(opt) 0.2820   2Q  683

    Complete-graph XY needs all-to-all connectivity, which routes badly on
    heavy-hex; ring is both cheaper AND better here. reps must be >= 3: at
    reps=2 the optimiser minimises <H> by rotating deterministically onto a
    single suboptimal basis state, giving 100% feasibility and P(opt) = 0.

    Uses TQA (Trotterized Quantum Annealing) warm starts at several dt scales,
    plus random restarts. Returns (bound_circuit, optimal_params_dict, min_value).
    """
    from qiskit.primitives import StatevectorEstimator
    from scipy.optimize import minimize

    qc, H, _, _ = build_xy_qaoa(problem, reps=reps, normalize=True, topology=topology)
    est = StatevectorEstimator(seed=seed)
    order = list(qc.parameters)

    if objective == "mean":
        # Untouched from the original so shipped artefacts reproduce exactly.
        def cost(x: np.ndarray) -> float:
            bound = qc.assign_parameters(dict(zip(order, x)))
            return float(est.run([(bound, H)]).result()[0].data.evs)
    elif objective == "cvar":
        if not 0.0 < alpha <= 1.0:
            raise ValueError(f"alpha must be in (0, 1], got {alpha}")
        from qiskit.quantum_info import Statevector
        energies, _feasible = _basis_energies(problem)
        energy_order = np.argsort(energies)

        def cost(x: np.ndarray) -> float:
            bound = qc.assign_parameters(dict(zip(order, x)))
            probs = np.abs(Statevector(bound).data) ** 2
            return _cvar(probs, energies, energy_order, alpha)
    else:
        raise ValueError(f"objective must be 'mean' or 'cvar', got {objective!r}")

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
