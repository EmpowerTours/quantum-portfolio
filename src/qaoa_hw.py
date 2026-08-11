"""QAOA on real IBM hardware, with and without error mitigation.

Methodology (standard for NISQ + conserves QPU time):
  1. Build the cost Hamiltonian from the portfolio QUBO.
  2. Optimize QAOA angles on a noiseless simulator (free, fast).
  3. Run the single tuned circuit on a real QPU: raw vs error-mitigated.
  4. Score each by P(optimal) — how often it samples the known-optimal portfolio.

The headline metric is P(optimal): exact=1.0 by definition; error mitigation
should lift the hardware value above the raw run. That is the "quantum utility"
story in one number.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from qiskit.circuit.library import QAOAAnsatz
from qiskit.primitives import StatevectorEstimator, StatevectorSampler
from qiskit.transpiler.preset_passmanagers import generate_preset_pass_manager
from qiskit_optimization.converters import QuadraticProgramToQubo
from scipy.optimize import minimize

from .problem import PortfolioProblem


@dataclass
class SampleScore:
    method: str
    best_selection: list[int]
    best_objective: float
    p_optimal: float          # fraction of shots landing on the optimal portfolio
    backend: str
    job_id: str | None = None
    # --- diagnostics without which p_optimal cannot be interpreted ----------
    # An external review pointed out that the artefact reported p_optimal with
    # no way to tell a working circuit from a depolarised one. These make the
    # difference visible: `feasible_fraction` separates "the constraint held"
    # from "we sampled noise" (uniform noise over n qubits gives
    # C(n,k)/2**n), and `mean_feasible_objective` supports an approximation
    # ratio that is an EXPECTATION rather than a best-of-N order statistic —
    # the latter is achieved by pure noise with probability ~1.
    feasible_fraction: float = 0.0
    mean_feasible_objective: float | None = None
    two_qubit_gates: int | None = None
    circuit_depth: int | None = None
    # Raw measurement counts. Shipped in the artefact so a reviewer can
    # recompute P(optimal), the feasible fraction and the approximation ratio
    # independently. Previously only summary scalars were stored, which made
    # the headline numbers unverifiable — and Qiskit Runtime job results are
    # scoped to the owning IBM account, so "verifiable on quantum.ibm.com"
    # was not something a third party could actually do.
    counts: dict[str, int] | None = None


def build_cost_hamiltonian(problem: PortfolioProblem):
    """Fold the budget constraint into a penalty and produce an Ising operator."""
    qubo = QuadraticProgramToQubo().convert(problem.qp)
    hamiltonian, offset = qubo.to_ising()
    return hamiltonian, offset, qubo


def _decode(bitstring: str, n: int) -> list[int]:
    # Qiskit counts are little-endian: rightmost char is qubit 0.
    bits = bitstring[::-1]
    return [i for i in range(n) if i < len(bits) and bits[i] == "1"]


def optimize_angles(problem: PortfolioProblem, reps: int = 2, maxiter: int = 80,
                    seed: int = 42):
    """Tune QAOA angles on a noiseless simulator. Returns (ansatz, optimal_params)."""
    hamiltonian, _, _ = build_cost_hamiltonian(problem)
    ansatz = QAOAAnsatz(cost_operator=hamiltonian, reps=reps)
    estimator = StatevectorEstimator(seed=seed)

    def cost(params):
        job = estimator.run([(ansatz, hamiltonian, params)])
        return float(job.result()[0].data.evs)

    rng = np.random.default_rng(seed)
    x0 = rng.uniform(0, np.pi, ansatz.num_parameters)
    res = minimize(cost, x0, method="COBYLA", options={"maxiter": maxiter})
    return ansatz, res.x


def circuit_cost(isa) -> tuple[int, int]:
    """(two-qubit gate count, depth) of a transpiled circuit.

    This is the single number that explains whether a hardware result means
    anything: a dense all-to-all penalty Hamiltonian routes to ~250 CZs on
    heavy-hex connectivity, and at Heron error rates that predicts a
    depolarised output. It was previously computed nowhere and reported
    nowhere.
    """
    ops = isa.count_ops()
    two_q = sum(c for g, c in ops.items() if g in ("cz", "cx", "ecr", "rzz"))
    return two_q, isa.depth()


def _score_counts(counts: dict[str, int], problem: PortfolioProblem,
                  optimal: list[int], method: str, backend: str,
                  job_id: str | None = None) -> SampleScore:
    n = problem.num_assets
    total = sum(counts.values())
    opt_set = set(optimal)
    p_opt = 0.0
    best_sel, best_obj = [], float("inf")
    feasible_shots, weighted_obj = 0, 0.0
    for bitstring, c in counts.items():
        sel = _decode(bitstring, n)
        if set(sel) == opt_set:
            p_opt += c / total
        if len(sel) == problem.budget:  # feasible
            x = np.zeros(n)
            x[sel] = 1
            obj = float(problem.qp.objective.evaluate(x))
            feasible_shots += c
            weighted_obj += obj * c
            if obj < best_obj:
                best_obj, best_sel = obj, sel
    return SampleScore(
        method, best_sel, best_obj, p_opt, backend, job_id,
        feasible_fraction=feasible_shots / total if total else 0.0,
        mean_feasible_objective=(weighted_obj / feasible_shots) if feasible_shots else None,
        counts=dict(counts),
    )


def sample_simulator(problem, ansatz, params, optimal, shots=4096, seed=42):
    qc = ansatz.assign_parameters(params)
    qc.measure_all()
    sampler = StatevectorSampler(seed=seed)
    res = sampler.run([qc], shots=shots).result()
    counts = res[0].data.meas.get_counts()
    return _score_counts(counts, problem, optimal, "QAOA (sim, tuned)", "statevector")


def _submit_with_retry(sampler, isa, shots, max_attempts=3, base_delay=2.0):
    """Submit the sampler job, retrying on transient network/queue failures.

    We retry on generic Exception but only for `max_attempts` total tries
    with exponential backoff. We do NOT retry on credential errors —
    those raise IBMRuntimeError or similar and shouldn't be papered over.
    """
    import time
    from qiskit_ibm_runtime.exceptions import IBMRuntimeError

    last_err = None
    for attempt in range(1, max_attempts + 1):
        try:
            return sampler.run([isa], shots=shots)
        except IBMRuntimeError:
            # Auth/permission/quota issues — re-raise immediately.
            raise
        except Exception as exc:
            last_err = exc
            if attempt < max_attempts:
                delay = base_delay * (2 ** (attempt - 1))
                print(f"  hardware submit attempt {attempt}/{max_attempts} "
                      f"failed: {type(exc).__name__}: {exc}. retrying in {delay:.0f}s")
                time.sleep(delay)
            else:
                raise
    # unreachable
    raise RuntimeError(f"sampler.run failed after {max_attempts} attempts: {last_err}")


#: Fixed so the raw and mitigated arms transpile to the SAME physical qubits.
#: Unseeded, `generate_preset_pass_manager` randomises layout on every call, so
#: each job landed on a different qubit set — visible in the shipped artefacts
#: as 498 vs 489 two-qubit gates for one logical circuit. The paired comparison
#: was therefore never "one circuit, two error-suppression settings", and layout
#: variation contaminated the run-to-run variance we attributed to drift.
TRANSPILER_SEED = 42


def sample_hardware(problem, ansatz, params, optimal, backend, *, mitigate: bool,
                    shots=4096):
    """Run the tuned circuit once on a real QPU. mitigate toggles DD + meas twirling.

    Transient submit failures are retried (exponential backoff, 3 attempts).
    Authentication/quota errors are raised immediately so they're visible.
    Once the job is queued, `job.result()` blocks normally — no retry there,
    since the work is already paid for.
    """
    from qiskit_ibm_runtime import SamplerV2

    qc = ansatz.assign_parameters(params)
    qc.measure_all()
    pm = generate_preset_pass_manager(
        optimization_level=3, backend=backend, seed_transpiler=TRANSPILER_SEED
    )
    isa = pm.run(qc)

    sampler = SamplerV2(mode=backend)
    if mitigate:
        sampler.options.dynamical_decoupling.enable = True
        sampler.options.dynamical_decoupling.sequence_type = "XY4"
        sampler.options.twirling.enable_gates = True
        sampler.options.twirling.enable_measure = True
        label = "QAOA (hw, mitigated)"
    else:
        sampler.options.dynamical_decoupling.enable = False
        sampler.options.twirling.enable_gates = False
        sampler.options.twirling.enable_measure = False
        label = "QAOA (hw, raw)"

    two_q, depth = circuit_cost(isa)
    job = _submit_with_retry(sampler, isa, shots)
    res = job.result()
    counts = res[0].data.meas.get_counts()
    score = _score_counts(counts, problem, optimal, label, backend.name, job.job_id())
    score.two_qubit_gates, score.circuit_depth = two_q, depth
    return score
