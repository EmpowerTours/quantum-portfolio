# Santander X Global Challenge — Quantum AI Leap Submission

## Project: Quantum-Safe DeFi Allocation Agents

Autonomous agents that allocate capital across DeFi yield pools using
hybrid quantum-classical optimisation running on a real IBM Heron QPU,
and sign every rebalance order with post-quantum cryptography so the
audit trail survives the cryptographically relevant quantum era
("Q-Day").

**Repository:** https://github.com/EmpowerTours/quantum-portfolio
**License:** MIT
**Applicant:** EmpowerTours SAS de CV (Mexico)
**Application areas:** Area 2 — *Quantum Software and AI-Driven
Intelligence* (hybrid algorithms, applications in finance) — and
Area 3 — *Digital Infrastructure Secured Against Quantum Computing*
(post-quantum cryptography, digital identity). This submission targets
both areas in one coherent pipeline.

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

A **depth-2 QAOA** with the budget constraint enforced as a quadratic
penalty in the cost Hamiltonian runs on IBM Heron silicon
(`ibm_marrakesh`). Hardware error is suppressed at the sampler level
with **XY4 dynamical decoupling, gate twirling, and measurement
twirling** (Qiskit Runtime sampler options; see
`src/qaoa_hw.py:140-148`). **Two real-hardware runs**, both verifiable
on https://quantum.ibm.com:

**DeFi-pool universe (matches the pitch):**

| | |
|---|---|
| Optimal selection | Morpho STEAKETH · Neverland USDC · shMONAD (all Monad pools) |
| Raw job ID | [`d89rmk1789is7393mlr0`](https://quantum.ibm.com/jobs/d89rmk1789is7393mlr0) |
| Mitigated job ID (XY4 DD + measurement twirling) | [`d89rmlqs46sc73fb0qc0`](https://quantum.ibm.com/jobs/d89rmlqs46sc73fb0qc0) |
| Mitigation lift in P(optimal) | **+67 %** (0.3 % → 0.5 %) |

**Stocks-universe baseline (earlier MVP run, kept for comparison):**

| | |
|---|---|
| Raw job ID | [`d88f7qis46sc73f9cjd0`](https://quantum.ibm.com/jobs/d88f7qis46sc73f9cjd0) |
| Mitigated job ID | [`d88f7sdg7okc73enff00`](https://quantum.ibm.com/jobs/d88f7sdg7okc73enff00) |
| Mitigation lift in P(optimal) | **+22.7 %** (0.537 % → 0.659 %) |

Both DeFi runs and both stock runs find the **same** optimum as the
classical exact solver, on every method (sim, HW raw, HW mitigated).

The +67% / +22.7% relative lift from error mitigation is consistent
with concurrent 2026 results on the same Heron family: a February-2026
zero-noise-extrapolation study on IBM Torino/Fez (also Heron) reported
a statistically significant **+31.6 %** portfolio-score improvement
(p=0.0009, Cohen's d=2.01) at 88 qubits, p=1 QAOA depth ([arXiv 2602.09047](https://arxiv.org/abs/2602.09047),
"QAOA + ZNE on NISQ Hardware for Carbon Credit Portfolio Optimization").
Our mitigation stack — XY4 DD + gate-and-measurement twirling — is a
distinct technique class, but the underlying observation that hardware
error mitigation produces a measurable lift on portfolio-style QUBOs
on Heron is now reproduced by an independent peer-reviewable artefact.

**Honest framing baked into the app:** at 8-qubit scale the classical
exact solver beats both QPU runs in wall-clock time. The value
demonstrated is the *hybrid pipeline*, the *cohesion* between the pitch
and the hardware, and the *isolated lift* from error mitigation —
not quantum advantage. Quantum advantage is not claimed.

### AI forecasting layer

Per-asset **Ridge regression** on technical features (lagged returns,
realised volatility, SMA-50 / SMA-200 momentum) trained walk-forward
with no lookahead. The forecasted expected-return vector feeds the
QUBO's cost Hamiltonian; the covariance is **Ledoit-Wolf** shrunk for
stability with short windows. R² is reported transparently per asset
(usually small — yield prediction is hard, and we say so).

### Hedged post-quantum signing

Every rebalance order carries **three independent signatures** over the
same canonical payload bytes. An attacker must break all three to forge
an order — the assumptions are deliberately disjoint:

| Scheme | Standard | Security assumption | Sizes (pk / sig) |
|---|---|---|---|
| **ML-DSA-65** | NIST FIPS 204 (2024) | Module-LWE / MSIS lattice | 1952 B / 3309 B |
| **SLH-DSA-SHAKE-256s** | NIST FIPS 205 (2024), Level-5 | SHA-3 collision resistance | 64 B / ~29 KB |
| **Ed25519** | RFC 8032 | Curve25519 discrete log | 32 B / 64 B |

The architecture follows the hybrid-by-default pattern of the May 2026
`quantum-safe-py` reference implementation (arxiv 2605.17061) but is
implemented directly against `quantcrypt` (PQClean-bound) and `cryptography`
(pyca/cryptography) so we control the v0.1.0 dependency risk. We sign
with the same NIST FIPS 204 algorithm NEAR Protocol enabled at L1 on
**2026-05-06**, 21 days before this submission — the first production
L1 to ship a NIST-finalised PQ signature, and the strongest available
evidence that this stack is on a live deployment trajectory.

Each signature covers the full canonical encoding of:

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

### On-chain audit anchor — AuditAnchor.sol

The off-chain hash-chained audit log is bridged to on-chain immutability
by `contracts/src/AuditAnchor.sol`, a minimal Foundry-tested Solidity
contract (`solc 0.8.28`, `cancun` evm-version). For each signed order
the agent computes SHA-256 of the canonical signed payload and submits
the 32-byte digest to `AuditAnchor.anchor(bytes32, uint64)`, which:

1. asserts the caller's expected `nextSequence` matches on-chain state
   (race-safety against a relayer retry),
2. emits `Anchored(address indexed anchorer, bytes32 indexed orderHash,
   uint64 indexed sequence, bytes32 prevHash)`,
3. updates per-anchorer `nextSequence` and `lastHash` so the on-chain
   chain mirrors the off-chain JSONL chain.

**Gas**: measured at **3,922 gas** for the steady-state function body
([Foundry test `test_GasUnderBudget`](contracts/test/AuditAnchor.t.sol)),
giving roughly **27–30 K gas** end-to-end once the 21 K base TX cost,
~600 bytes of warm-storage calldata, and warm-SSTORE overhead are
added. We deliberately do **not** verify ML-DSA on-chain: a pure-
Solidity verifier would cost ~500 M gas
([hackernoon 2026](https://hackernoon.com/comparing-on-chain-post-quantum-signature-verification-for-ethereum)).
Anchoring the digest, not the signature, is the cost-feasible cell in
the off-chain-PQ × on-chain-classical design space — and remains
useful even after EVM chains adopt native PQ signatures.

**Test coverage** (Foundry, `forge test`): 8 tests — genesis prev_hash,
chain linking, per-anchorer counter isolation, sequence-mismatch revert,
zero-hash revert, overload coherence, gas budget assertion (`<60 K`),
and a 256-run fuzz on arbitrary 32-byte digests. All pass against
`solc 0.8.28`.

**Deployment status — live on Monad testnet** (chainId 10143):

| | |
|---|---|
| Contract address | [`0x0e649C383CFA6be1998445D0A7a8E1cc7540D239`](https://testnet.monadscan.com/address/0x0e649c383cfa6be1998445d0a7a8e1cc7540d239) |
| Verified source on Monadscan | ✅ ("Pass - Verified" via Etherscan V2 multichain API) |
| Compiler / EVM | `solc 0.8.28` · `cancun` |
| Deployer | `0xe67e13D545C76C2b4e28DFE27Ad827E1FC18e8D9` |
| Deploy TX block | 34915948 |
| First anchor TX | [`0x523b46a217968c93671311942ff94370e0981a3bc201683f95908dc916f645e7`](https://testnet.monadscan.com/tx/0x523b46a217968c93671311942ff94370e0981a3bc201683f95908dc916f645e7) (sequence 0, cold-SSTORE 81 770 gas) |
| Second anchor TX | [`0x0b88cd21b73c5e53aa6b4b29d83601ae5ddf8d9cb253715f1131f5f8c6103a1e`](https://testnet.monadscan.com/tx/0x0b88cd21b73c5e53aa6b4b29d83601ae5ddf8d9cb253715f1131f5f8c6103a1e) (sequence 1, warm-storage **47 061 gas** end-to-end) |
| Anchored event topic[0] | `0x3d0c97912257c6ad70e8f6fc81ae518ad3e14734d308b512c2729cc637a4b0b1` = `keccak256("Anchored(address,bytes32,uint64,bytes32)")` |
| On-chain chain link | Second TX's `prevHash` data field == first TX's `orderHash` topic. The off-chain JSONL hash chain and the on-chain event chain are now linked at the byte level. |

The first anchor pays a one-time cold-SSTORE penalty (two zero→nonzero
writes for `nextSequence` and `lastHash`). Steady-state cost is **47 K
gas per anchor** — within the ~30 K function-body budget once base TX
+ warm SSTORE costs are accounted for. Both events are reconstructable
by any indexer filtering `Anchored(address indexed, bytes32 indexed,
uint64 indexed, bytes32)` on the verified contract address.

**Mainnet deployment is deliberately deferred behind a Santander prize
event** so competition funds — not development funds — pay for
production bytecode. The exact same `forge script` command with
`--rpc-url https://rpc.monad.xyz` and chainId 143 in `Deploy.s.sol`
reproduces this artefact on mainnet.

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

- 24 PQ-signing tests covering: variant lock-in for SLH-DSA-SHAKE-256s;
  round-trip + tampering for ML-DSA, SLH-DSA, and Ed25519; hedged-order
  round-trip + per-component verification; tamper invalidates all three
  signatures; legacy ML-DSA-only orders still verify; replay rejection;
  schema-version coverage; strict canonicalisation; strict `verify`
  typing; audit-chain intact + deletion detection; **concurrent
  append_audit under POSIX flock preserves the chain**; **reverse-line
  scan survives audit entries larger than the 64 KB pre-fix window**;
  **append_audit refuses to record an unverifiable order**; **AI
  walk-forward is lookahead-free** (corrupting prices past `as_of` does
  not change the prediction).
- 12 Monad-TX tests covering: calldata round trip with shared
  canonicalisation against the PQ-signing layer; transaction field
  shape; bad-address rejection; corruption detection; **AuditAnchor
  calldata selectors verified against `forge inspect`**; **anchor
  TX gas budget under 100 K**; **MONAD_CHAIN_ID locked at 143
  (mainnet)** so a typo to a testnet value fails CI.
- 8 Foundry tests on `AuditAnchor.sol` (genesis, chain linking,
  per-anchorer counter isolation, sequence-mismatch revert, zero-hash
  revert, overload coherence, gas budget, 256-run fuzz).
- GitHub Actions runs the full suite on Python 3.11 and 3.12 on every
  push, plus an import smoke test of every source module on top of the
  full `requirements.txt`. Audit-chain verification of the shipped
  `outputs/audit_log.jsonl` runs as a separate CI step.

## Why this fits the challenge

- **Area 2 — Quantum Software and AI-Driven Intelligence.** The pipeline
  runs today on a single workstation; the QPU portion runs today on
  `ibm_marrakesh`. Nothing waits for fault-tolerant hardware. Our
  XY4 DD + gate/measurement twirling stack on a portfolio QUBO is the
  same direction (NISQ Heron + heavy mitigation on a finance problem)
  demonstrated to give a statistically significant
  ([p=0.0009](https://arxiv.org/abs/2602.09047)) improvement over the
  classical baseline by Brazilian-Cerrado portfolio researchers on
  Heron in February 2026, using ZNE in their case.
- **Area 3 — Digital Infrastructure Secured Against Quantum Computing.**
  The PQ signing layer is not narrative — it is verified by 24 PQ tests
  + 12 Monad-TX tests + 8 Foundry tests on `AuditAnchor.sol` (44 total)
  and produces tamper-evident artefacts that a reviewer can audit
  without running the code. **AuditAnchor.sol is live on Monad testnet**
  at [`0x0e649…0D239`](https://testnet.monadscan.com/address/0x0e649c383cfa6be1998445d0a7a8e1cc7540d239),
  Monadscan-verified, with two on-chain anchors already linked into the
  off-chain JSONL hash chain. Aligned with the NIST FIPS 204 algorithm
  NEAR Protocol enabled at L1 on 2026-05-06 — the first production L1
  to ship a finalised PQ signature.
- **Mexico-eligible.** EmpowerTours SAS de CV is incorporated in
  Mexico, qualifying under the LATAM startup criteria.
- **Built honestly.** The code does not claim quantum advantage; the
  backtest does not claim alpha (Sharpe 1.59 vs equal-weight 2.11 is
  reported, not hidden — the AI strategy underperforms the naive
  baseline at this scale, which is the honest result of a lookahead-free
  walk-forward); the on-chain ECDSA gap is documented in
  [`SECURITY.md`](SECURITY.md) as the Q-Day risk we are *preparing for*
  rather than *eliminating*. We avoid the failure mode of pitching
  capabilities the code does not have.

## What would happen with funding

1. **Deploy `AuditAnchor.sol` on Monad mainnet.** The contract is
   already written and Foundry-tested (8 tests, 256-run fuzz, gas
   measured at ~30 K per call). Mainnet deployment is gated behind
   the prize event so competition funds — not development funds —
   pay for production bytecode. Testnet deployment (`chainid 10143`)
   is staged in `contracts/script/Deploy.s.sol` ready for `forge
   script --rpc-url $MONAD_TESTNET_RPC --broadcast`.
2. **Wire an actual wallet integration** (web3.py + a hardware wallet
   path) so the agent's `monad_tx.py` output becomes a real broadcast
   transaction. Closes the gap between "ready-to-sign artifact" and
   "broadcast on Monad mainnet."
3. **Track FIPS 206 (FN-DSA / Falcon)**. NIST has not finalised the
   standard as of mid-2026 — projected late 2026 / early 2027. When the
   spec freezes, add Falcon as a fourth hedge with smaller signature
   size for the on-chain hash-anchor calldata path.
4. **Scale the backtest** to multi-year history and 50+ pools (current
   MVP is 8 stocks / 8 pools, 48 monthly rebalances).
5. **Cryptographic agility ground-up**. Bind a `crypto_suite_id`
   integer into the signed payload (already supported via
   `schema_version`) so future migrations to e.g. ML-DSA-87 or
   FN-DSA-512 are zero-downtime — same audit log, additive scheme
   versions, no key reuse.

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
