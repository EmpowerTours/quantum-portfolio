# Quantum-Safe DeFi Allocation Agents

End-to-end pipeline for autonomous DeFi yield-pool selection that uses
hybrid quantum-classical optimisation and signs every rebalance order
with post-quantum cryptography.

- **Quantum**: portfolio QUBO solved with **depth-2 QAOA** (budget
  enforced as a quadratic penalty in the cost Hamiltonian) on a real
  IBM Heron QPU (`ibm_marrakesh`), raw and with XY4 dynamical
  decoupling + gate and measurement twirling for error suppression.
  Verifiable job IDs are baked into the artefacts.
- **AI**: per-asset Ridge regression with technical features, trained
  walk-forward (no lookahead), feeds the QUBO's expected-return vector.
  Covariance is Ledoit-Wolf shrunk.
- **Post-quantum security**: every rebalance order is signed with
  **ML-DSA-65 (NIST FIPS 204)**, the lattice-based signature scheme
  finalised in 2024. Nonces are tracked to prevent replay; mutated
  fields invalidate the signature; the audit log is JSON-lines.
- **DeFi-native**: live data from DeFiLlama. Pool universe is
  Monad-primary (Morpho, Upshift, Neverland, shMONAD) plus Ethereum
  stablecoin pools for breadth.
- **Honest framing**: at this scale a classical exact solver is faster
  than the QPU. The value is the hybrid pipeline + error-mitigation
  demonstration + Q-Day-ready off-chain order layer.

This is the submission artefact for the **Santander X Global Challenge:
Quantum AI Leap** (Pillar 2 + Pillar 3, application deadline
2026-06-30). See [`SUBMISSION.md`](SUBMISSION.md) for the application
narrative and [`SECURITY.md`](SECURITY.md) for the threat model.

## Demo

```sh
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt        # or use whichever package manager
streamlit run app.py
```

Tabs (left-to-right): **Run optimizer** (classical exact vs QAOA on
simulator), **AI forecasts** (Ridge predictions per pool), **Backtest**
(walk-forward monthly rebalance), **Hardware verification** (IBM Heron
results with clickable job IDs), **PQ signing** (interactive sign +
tamper test + audit log), **Methodology** (the architecture in plain
English).

## Verifiable hardware results

Two real-hardware runs on `ibm_marrakesh` (IBM Heron r2, 156 qubits) —
both depth-2 penalty-QAOA on 8 qubits at 4096 shots. Hardware error
suppression: XY4 dynamical decoupling + gate and measurement twirling.
Both runs find the same best 3-of-8 portfolio as the classical exact
solver, which is consistency at this scale (not advantage).

### DeFi pool universe (current, matches the pitch)

| | |
|---|---|
| Optimal selection | Morpho STEAKETH · Neverland USDC · shMONAD (all Monad) |
| Raw job ID | [`d89rmk1789is7393mlr0`](https://quantum.ibm.com/jobs/d89rmk1789is7393mlr0) |
| Mitigated job ID | [`d89rmlqs46sc73fb0qc0`](https://quantum.ibm.com/jobs/d89rmlqs46sc73fb0qc0) |
| Mitigation lift in P(optimal) | **+67 %** (0.3 % → 0.5 %) |

### MVP stock universe (earlier baseline, kept for comparison)

| | |
|---|---|
| Optimal selection | GLD · SLV · NVDA |
| Raw job ID | [`d88f7qis46sc73f9cjd0`](https://quantum.ibm.com/jobs/d88f7qis46sc73f9cjd0) |
| Mitigated job ID | [`d88f7sdg7okc73enff00`](https://quantum.ibm.com/jobs/d88f7sdg7okc73enff00) |
| Mitigation lift in P(optimal) | **+22.7 %** (0.537 % → 0.659 %) |

## Reproducing

```sh
# 1. Re-run the QAOA on real hardware (needs IBM_QUANTUM_TOKEN in .env)
python run_hardware.py

# 2. Sign the resulting order with ML-DSA-65 + verify + write audit log
python run_pq_demo.py

# 3. Run the test suite (PQ signing round-trips, replay protection, etc.)
python tests/test_pq_signing.py

# 4. Run the walk-forward backtest with AI-forecast μ
python run_backtest.py
```

## Project layout

```
.
├── app.py                       Streamlit UI (6 tabs)
├── run_demo.py                  Classical + QAOA-sim demo
├── run_hardware.py              QAOA on real IBM Heron QPU
├── run_backtest.py              Walk-forward backtest
├── run_pq_demo.py               PQ-sign a real hardware order
├── src/
│   ├── ai_forecast.py           Ridge regression forecasts
│   ├── backtest.py              Walk-forward engine
│   ├── data.py                  Yahoo-Finance stock-data layer
│   ├── defi_data.py             DeFiLlama yield-pool data layer
│   ├── hardware.py              IBM Quantum Runtime connection
│   ├── orders.py                RebalanceOrder + audit log
│   ├── pq_signing.py            ML-DSA-65 signing primitives
│   ├── problem.py               Portfolio QUBO builder
│   ├── qaoa_hw.py               Penalty-QAOA on hardware (raw / mitigated)
│   ├── solvers.py               Classical exact + QAOA-sim solvers
│   └── xy_qaoa.py               XY-mixer QAOA reference implementation (not in current HW path)
├── tests/
│   └── test_pq_signing.py       7 round-trip + tampering tests
├── outputs/
│   ├── hardware_run.json        Cached IBM-QPU result
│   ├── backtest.json            Walk-forward metrics
│   ├── signed_orders.json       Signed-order aggregate
│   └── *.png                    Charts
├── SECURITY.md                  Threat model + reproducibility
└── SUBMISSION.md                Santander X application narrative
```

## Acknowledgements

QAOA comes from Farhi et al. (2014). The portfolio formulation follows
Mugel et al. (2022). The XY-mixer reference implementation in
`src/xy_qaoa.py` follows Hadfield et al. (2017) but is not on the
current hardware path. ML-DSA-65 follows NIST FIPS 204 (2024); we use
the `dilithium-py` pure-Python implementation by Giacomo Pope.

## License

MIT — see [`LICENSE`](LICENSE).
