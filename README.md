# Quantum-Safe DeFi Trading Agents

End-to-end pipeline for autonomous DeFi yield-pool selection that uses
hybrid quantum-classical optimisation and signs every rebalance order
with post-quantum cryptography.

- **Quantum**: portfolio QUBO solved with XY-mixer QAOA (Hadfield et al.'s
  Quantum Alternating Operator Ansatz, Hamming-weight-conserving) on a
  real IBM Heron QPU (`ibm_marrakesh`), raw and with dynamical-decoupling
  + measurement-twirling error mitigation. Verifiable job IDs are baked
  into the artefacts.
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
2026-06-30). See [`SECURITY.md`](SECURITY.md) for the threat model and
the explicit list of what the code does and does not protect against.

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

| | |
|---|---|
| Backend | `ibm_marrakesh` (IBM Heron r2, 156 qubits) |
| Circuit | depth-2 XY-mixer QAOA, 8 qubits |
| Shots | 4096 per run |
| Raw job ID | [`d88f7qis46sc73f9cjd0`](https://quantum.ibm.com/jobs/d88f7qis46sc73f9cjd0) |
| Mitigated job ID | [`d88f7sdg7okc73enff00`](https://quantum.ibm.com/jobs/d88f7sdg7okc73enff00) |
| Mitigation lift in P(optimal) | **+22.7 %** (0.537 % → 0.659 %) |

The mitigated circuit uses XY4 dynamical decoupling on idle qubits +
gate and measurement twirling. Both runs find the same best
3-of-8 portfolio (`GLD, SLV, NVDA`) as the classical exact solver — at
this scale that is consistency, not advantage.

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
│   ├── qaoa_hw.py               QAOA on hardware (raw / mitigated)
│   ├── solvers.py               Classical exact + QAOA-sim solvers
│   └── xy_qaoa.py               XY-mixer QAOA (Hamming-conserving)
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

QAOA and the XY mixer come from Farhi et al. (2014) and Hadfield et al.
(2017) respectively. The portfolio formulation follows Mugel et al.
(2022). ML-DSA-65 follows NIST FIPS 204 (2024); we use the
`dilithium-py` pure-Python implementation by Giacomo Pope.

## License

MIT — see [`LICENSE`](LICENSE).
