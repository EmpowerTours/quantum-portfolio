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
- **Hedged post-quantum security**: every rebalance order is triple-signed
  with **ML-DSA-65** (FIPS 204, lattice PQ), **SLH-DSA-SHAKE-256s**
  (FIPS 205, hash-based PQ, Level-5), and **Ed25519** (RFC 8032, classical).
  Three independent security assumptions — an attacker must break all
  three to forge an order. Nonces are tracked to prevent replay;
  mutated fields invalidate every signature; the audit log is
  hash-chained JSON-lines.
- **DeFi-native**: live data from DeFiLlama. Pool universe is
  Monad-primary (Morpho, Upshift, Neverland, shMONAD) plus Ethereum
  stablecoin pools for breadth.
- **Honest framing**: at this scale a classical exact solver is faster
  than the QPU. The value is the hybrid pipeline + error-mitigation
  demonstration + Q-Day-ready off-chain order layer.

This is the submission artefact for the **Santander X Global Challenge:
Quantum AI Leap** (Area 3 primary + Area 2 secondary, application deadline
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
| Single-run P(optimal) raw / mitigated | 0.3 % → 0.5 % (directional consistency check, single 4 096-shot run — see SUBMISSION.md for Wilson CIs + Fisher exact p ≈ 0.16; **not** a significance-tested lift) |

### MVP stock universe (earlier baseline, kept for comparison)

| | |
|---|---|
| Optimal selection | GLD · SLV · NVDA |
| Raw job ID | [`d88f7qis46sc73f9cjd0`](https://quantum.ibm.com/jobs/d88f7qis46sc73f9cjd0) |
| Mitigated job ID | [`d88f7sdg7okc73enff00`](https://quantum.ibm.com/jobs/d88f7sdg7okc73enff00) |
| Single-run P(optimal) raw / mitigated | 0.537 % → 0.659 % (directional consistency check, single 4 096-shot run; Fisher exact p ≈ 0.49 — not significance-tested) |

## Reproducing

**See SUBMISSION.md → "Reproducing the artefacts" for the two valid
review paths (A: verify the shipped state; B: rerun the pipeline fresh).
Path A is what reviewers should run first** — do NOT run
`python run_pq_demo.py` before the verification step, because it
overwrites the shipped `outputs/signed_orders.json` and produces a
new orderHash that will not match our on-chain anchors.

### Quick setup (one-time)

```sh
# Python 3.12 recommended (CI tests 3.11 and 3.12; 3.13 may break qiskit wheels).
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Foundry (if not installed):
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Forge-std (needed for `forge test`; not vendored in the repo):
( cd contracts && forge install foundry-rs/forge-std --shallow --no-git )
```

### Path A — verify the shipped artefact

```sh
# 1. Python tests (28 PQ + 23 Monad-TX)
python tests/test_pq_signing.py
python tests/test_monad_tx.py

# 2. Foundry tests (8 AuditAnchor + 13 MonadAllocationVault + 12 RoutingVault)
( cd contracts && forge test )

# 3. Re-derive the canonical-bytes SHA-256 of the shipped signed order:
python -c "
import sys, hashlib; sys.path.insert(0,'.')
from src import orders, pq_signing as pq
print(hashlib.sha256(pq.canonical_bytes(orders.load_signed_orders()[0].order.to_dict())).hexdigest())
"
# Expected: fe44195b36463e33da7156285383a4fe735093ecadb1abb87684435552814ba9
# This must match AuditAnchor.lastHash[deployer] - see SUBMISSION.md for cast call.
```

### Path B — exercise the pipeline from scratch

⚠️ **This overwrites the shipped `outputs/*.json` and appends to
`outputs/audit_log.jsonl`.** Back them up if you want Path A
reproducibility afterwards.

```sh
# 1. Re-run the QAOA on real hardware (needs IBM_QUANTUM_TOKEN in .env)
python run_hardware.py

# 2. Sign a NEW order under fresh keys (overwrites outputs/)
python run_pq_demo.py

# 3. Walk-forward backtest with AI-forecast μ
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
│   ├── pq_signing.py            Hedged signing: ML-DSA + SLH-DSA + Ed25519
│   ├── problem.py               Portfolio QUBO builder
│   ├── qaoa_hw.py               Penalty-QAOA on hardware (raw / mitigated)
│   ├── solvers.py               Classical exact + QAOA-sim solvers
│   └── xy_qaoa.py               XY-mixer QAOA reference implementation (not in current HW path)
├── contracts/                   Foundry sub-project (solc 0.8.28)
│   ├── foundry.toml
│   ├── src/AuditAnchor.sol            ~30 K gas on-chain anchor for SHA-256(order)
│   ├── src/MonadAllocationVault.sol   native-MON vault recording per-orderHash deposits
│   ├── src/RoutingVault.sol           swaps anchored MON allocations through approved AMM pairs
│   ├── src/dex/MiniAMM.sol            minimal V2-style AMM used by RoutingVault tests/deploys
│   ├── test/AuditAnchor.t.sol         8 tests + 256-run fuzz
│   ├── test/MonadAllocationVault.t.sol  13 tests + 256-run fuzz
│   ├── test/RoutingVault.t.sol        12 route + slippage + invariant tests
│   ├── script/Deploy.s.sol            deploys AuditAnchor
│   ├── script/DeployVault.s.sol       deploys MonadAllocationVault
│   └── script/DeployDex.s.sol         deploys WMON + mock tokens + AMM pairs + RoutingVault
├── tests/
│   ├── test_pq_signing.py       28 round-trip + tampering + concurrency + schema + Unicode + NaN tests
│   └── test_monad_tx.py         23 calldata + AuditAnchor + vault tests
│   (Plus 33 Foundry tests in contracts/test/ above — 84 tests total)
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
current hardware path. ML-DSA-65 follows NIST FIPS 204 (2024) and
SLH-DSA-SHAKE-256s follows NIST FIPS 205 (2024); both are provided by
`quantcrypt` (PQClean precompiled bindings). The Ed25519 classical leg
uses pyca's `cryptography` library. The triple-sign hedge construction
is the standard hybrid-PQ pattern (one lattice + one hash-based + one
classical signature with disjoint security assumptions).

## License

MIT — see [`LICENSE`](LICENSE).
