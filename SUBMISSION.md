# Santander X Global Challenge — Quantum AI Leap Submission

## Project: Quantum-Safe DeFi Trading Agents

Autonomous agents that allocate capital across DeFi yield pools using
hybrid quantum-classical optimisation running on a real IBM Heron QPU,
and sign every rebalance order with post-quantum cryptography so the
audit trail survives the cryptographically relevant quantum era
("Q-Day").

**Repository:** https://github.com/EmpowerTours/quantum-portfolio
**License:** MIT
**Applicant:** EmpowerTours SAS de CV (Mexico)
**Application areas:** Pillar 2 (Quantum + AI for real problems) and
Pillar 3 (Post-quantum cryptography / digital security)

---

## The problem in one paragraph

DeFi yield optimisation is a real, ongoing financial decision: at any
moment a portfolio of stablecoin and ETH-equivalent pools offers
heterogeneous APYs and correlated yield risk. The optimal subset
selection is a binary quadratic problem that is exactly the QUBO format
QPUs target. **Separately**, every wallet on every production chain
today signs transactions with ECDSA, which Shor's algorithm on a
sufficiently large QPU breaks. The two problems converge at the same
desk: the same engineering team that adopts QPU optimisation must also
prepare for Q-Day risk to their existing ECDSA workflows. This project
addresses both inside one coherent pipeline.

## What we ship

### Verifiable quantum hardware execution

A depth-2 QAOA with an **XY-mixer** (Hamadfield et al.'s
Quantum Alternating Operator Ansatz, Hamming-weight-conserving) runs on
IBM Heron silicon (`ibm_marrakesh`). Two job IDs are baked into the
artefacts and verifiable on https://quantum.ibm.com:

| | |
|---|---|
| Raw run | [`d88f7qis46sc73f9cjd0`](https://quantum.ibm.com/jobs/d88f7qis46sc73f9cjd0) |
| Mitigated run (XY4 DD + measurement twirling) | [`d88f7sdg7okc73enff00`](https://quantum.ibm.com/jobs/d88f7sdg7okc73enff00) |
| P(optimal) lift from mitigation | **+22.7 %** (0.537 % → 0.659 %) |
| Mitigated run finds the same optimum as the classical exact solver | ✓ |

**Honest framing baked into the app:** at 8-qubit scale the classical
exact solver beats both QPU runs in wall-clock time. The value
demonstrated is the *hybrid pipeline* and the *isolated lift* from
error mitigation, not quantum advantage. Quantum advantage is not
claimed.

### AI forecasting layer

Per-asset **Ridge regression** on technical features (lagged returns,
realised volatility, SMA-50 / SMA-200 momentum) trained walk-forward
with no lookahead. The forecasted expected-return vector feeds the
QUBO's cost Hamiltonian; the covariance is **Ledoit-Wolf** shrunk for
stability with short windows. R² is reported transparently per asset
(usually small — yield prediction is hard, and we say so).

### Post-quantum signing

Every rebalance order is signed with **ML-DSA-65 (NIST FIPS 204)**, the
lattice-based signature scheme NIST finalised in 2024 for general-purpose
post-quantum protection. Key sizes match the FIPS spec exactly (pk
1952 B, sk 4032 B, sig ≤ 3309 B). The signature covers:

- Pool selection and weights
- Expected return and volatility
- **The originating QPU job ID** (so the audit trail links each order
  back to its hardware computation)
- A UUID4 nonce — tracked in the audit log to block replay
- The order's schema version — so layout changes cannot be silently
  abused
- An ISO-8601 UTC timestamp

The audit log is a **hash-chained JSON-lines file**: each entry carries
the SHA-256 of the previous entry. `verify_audit_chain()` walks the file
and detects deletions, reorderings, and middle edits — append-only
forward extension is the only mutation that survives.

### Unsigned Monad transaction

`src/monad_tx.py` produces an **unsigned EIP-1559 transaction**
(chainId 143) with the signed order embedded in calldata. A wallet —
the agent never holds the wallet key — provides the ECDSA signature
that lets the chain accept the transaction. This is **two-key custody**
by design: the agent's PQ key authorises intent, the wallet's ECDSA
key authorises execution. Either alone is insufficient.

### DeFi-native data layer

Live pool data from **DeFiLlama**'s public API, with a curated
universe centred on **Monad-native pools** (Morpho STEAKETH, Upshift
earnAUSD, Neverland USDC, shMONAD) plus Ethereum stablecoin pools
(Sky sUSDS, Ethena sUSDe, Maple USDC) for breadth and EVM reachability.
A toggle in `run_hardware.py` swaps the QPU run between the cached MVP
stock universe and the live DeFi pool universe.

### Streamlit UI for evaluation

Six tabs covering the whole pipeline — Run optimiser, AI forecasts,
Backtest, Hardware verification (with clickable IBM Quantum job-ID
links), PQ signing (interactive sign + tamper test + chain status +
unsigned Monad TX viewer), and Methodology. Designed so a Santander
panellist can poke every component without reading source.

## Test coverage and CI

- 12 PQ-signing tests (round trip, tampering, replay rejection, schema
  version coverage, strict canonicalisation, strict `verify` typing,
  audit-chain intact, audit-chain deletion detection)
- 4 Monad-TX tests (calldata round trip, transaction field shape, bad
  address rejection, corruption detection)
- GitHub Actions runs the full suite on Python 3.11 and 3.12 on every
  push, plus an import smoke test of every source module on top of the
  full `requirements.txt`

## Why this fits the challenge

- **Pillar 2 — Q+AI for real problems with short-to-medium-term impact.**
  The pipeline runs today on a single workstation; the QPU portion runs
  today on `ibm_marrakesh`. Nothing waits for fault-tolerant hardware.
- **Pillar 3 — Post-quantum digital security.** The PQ signing layer is
  not narrative — it is verified by 12 tests and produces tamper-evident
  artefacts that a reviewer can audit without running the code.
- **Mexico-eligible.** EmpowerTours SAS de CV is incorporated in
  Mexico, qualifying under the LATAM startup criteria.
- **Built honestly.** The code does not claim quantum advantage; the
  backtest does not claim alpha (Sharpe 1.48 vs equal-weight 1.87 is
  reported, not hidden); the on-chain ECDSA gap is documented in
  [`SECURITY.md`](SECURITY.md) as the Q-Day risk we are *preparing for*
  rather than *eliminating*. We avoid the failure mode of pitching
  capabilities the code does not have.

## What would happen with funding

1. **Re-run the QPU on the live DeFi universe** (~5 min QPU queue +
   ~30 s execution; the script already accepts `--universe defi`).
   Closes the last cohesion gap between the pitch and the hardware
   artefacts.
2. **Replace `dilithium-py` with `liboqs` C bindings** (~10× faster
   sign/verify; same API).
3. **Deploy an on-chain audit contract on Monad** that emits a hash of
   the signed order as a log event, anchoring the off-chain log to the
   chain.
4. **Wire an actual wallet integration** (web3.py + a hardware wallet
   path) so the agent's `monad_tx.py` output becomes a real broadcast
   transaction.
5. **Scale the backtest** to multi-year history and 50+ pools (current
   MVP is 8 stocks / 8 pools, 48 monthly rebalances).
6. **Submit `dmkde` (sister project)** to PyOD's detector catalogue for
   open-source visibility; tie it into the Streamlit app as an optional
   anomaly-detection layer on incoming pool data.

## Reproducing the artefacts

```sh
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# 1. Run the QAOA on real hardware (needs IBM_QUANTUM_TOKEN in .env)
python run_hardware.py
python run_hardware.py --universe defi   # live DeFiLlama pools

# 2. Sign the resulting order with ML-DSA-65, build unsigned Monad TX
python run_pq_demo.py

# 3. Tests
python tests/test_pq_signing.py
python tests/test_monad_tx.py

# 4. UI
streamlit run app.py
```

## Contact

GitHub issues at https://github.com/EmpowerTours/quantum-portfolio
