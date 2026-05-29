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

The triple-sign hedge construction is the standard hybrid-PQ pattern
(one lattice + one hash-based + one classical with disjoint security
assumptions); we implement it directly against `quantcrypt`
(PQClean-bound) and `cryptography` (pyca/cryptography) to control
dependency risk. We sign with the same NIST FIPS 204 algorithm NEAR
Protocol committed to at L1 on **2026-05-06** — the first major L1 to
commit to a NIST-finalised PQ signature at the account layer, with
testnet rollout planned for end of Q2 2026
([BanklessTimes, 2026-05-07](https://www.banklesstimes.com/articles/2026/05/07/near-protocol-soars-after-quantum-safe-signing-confirmed-for-q2/)).
NEAR's commitment is the strongest available signal that the standardised
ML-DSA stack is on a production-deployment trajectory, even if neither
NEAR nor we run it at L1-mainnet yet.

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
by design: the agent's PQ key authorises **intent**, the wallet's
ECDSA key authorises **on-chain custody** (the anchor + vault TX).
Either alone is insufficient.

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

### On-chain custody anchor — MonadAllocationVault.sol

AuditAnchor proves *that an agent decision existed*. The companion
contract `contracts/src/MonadAllocationVault.sol` proves *that a user
escrowed value referencing it*: the user signs a TX that deposits
native MON into the vault keyed by the agent's `orderHash`, and the
vault emits an `Allocated` event linking the wallet, the orderHash,
the amount, and the agent-selected pool weights.

**What this is and is not.** The vault is an **escrow + audit-event
contract**, not a DEX or yield router. It accepts native MON, records
per-user / per-orderHash deposit, emits an indexed event, and lets the
same user withdraw. It does **not** swap tokens, route to a DEX, or
generate yield — the deposited MON sits in the contract until the
depositor withdraws. The on-chain primitive shipped here is therefore
*custody-with-attribution*: the user has committed value against a
specific PQ-signed agent decision, and that commitment is a permanent
on-chain event indexers can replay. When a Monad-native DEX ships on
testnet (none exists today — see "Discovery" paragraph below) the
vault is upgraded to a routing-aware successor; the `Allocated` event
shape stays stable so historical orders remain replayable.

Why native MON, not a synthetic test token: the agent's recommendation
is denominated in real on-chain value the user actually controls.
Withdrawals are gated to msg.sender's own deposit slot — the user can
pull their MON back at any time with `withdraw(orderHash, amount)`.

**Discovery note on testnet DEX availability.** Six rounds of discovery
(GeckoTerminal, MonadVision, MCP-MONI config, mainnet Uniswap V3
deterministic addresses, Uniswap-deployer's actual CREATE2 outputs,
**Kuru's own official `docs.kuru.io/contracts/Contract-addresses`**)
returned zero working DEX contracts on the current Monad testnet —
all canonical router/token addresses listed in ecosystem docs have
empty bytecode on the live RPC. The testnet appears to have been
reset around 2025-12-16 and ecosystem documentation has not caught up.
Only Permit2 (deterministic CREATE2 redeploy) and the ERC-4337
EntryPoint are confirmed live. The custody-anchor design ships the
*agent-facing protocol* now; real DEX routing waits for the ecosystem.

**Live testnet deployment** (Monadscan-verified, same network/compiler
as AuditAnchor):

| | |
|---|---|
| Contract address | [`0xC39e298ce89cDfc934c697c9Fe0CC4BAA80B87f5`](https://testnet.monadscan.com/address/0xc39e298ce89cdfc934c697c9fe0cc4baa80b87f5) |
| Verified source on Monadscan | ✅ |
| Deploy script | `contracts/script/DeployVault.s.sol` |

**End-to-end provenance trail, demonstrated on testnet:**

| Step | Contract | TX | Gas |
|---|---|---|---|
| 1. Anchor `orderHash` on-chain | AuditAnchor | [`0x60d32b16…2da8e`](https://testnet.monadscan.com/tx/0x60d32b1610dfb28a630dd8f4a64d9c6a9bc4fa4ef2a99700f69c4ef84e62da8e) | 47 061 |
| 2. Escrow `0.01 MON` under `orderHash` | MonadAllocationVault | [`0x7be13153…18ef66`](https://testnet.monadscan.com/tx/0x7be13153bd7103d4cdbba3edd7ea4593a6e9579a69ca25a9790f0cbe6f18ef66) | 71 476 |

Both TXs reference the same `orderHash = 0xfe44195b…14ba9`, both from
the same wallet `0xe67e…e8D9`, three blocks apart. Off-chain
`outputs/signed_orders.json` contains the order whose canonical
SHA-256 equals that exact hash, signed under all three PQ schemes.

**Q-Day caveat on the on-chain leg.** The two on-chain TXs above are
signed with secp256k1 ECDSA (Monad's native scheme). A Shor-capable
adversary forges them on Q-Day, breaking the on-chain witness. The
**off-chain** signed_orders.json + audit_log.jsonl remain
PQ-tamper-evident — the agent's decision provenance survives Q-Day
even after the on-chain anchor becomes forgeable. When Monad (or the
chain we run on) ships a PQ-signed TX scheme, the anchor TX inherits
that protection without code changes to the agent. This is the
standard hybrid posture: the *audit trail* is quantum-safe today; the
*on-chain settlement* awaits chain-level PQ. SECURITY.md threat-model
row "Q-Day quantum attacker (on-chain)" documents this explicitly.

A reviewer verifies the full chain with:

```sh
# 1. Confirm the on-chain anchor's last hash for the agent's wallet.
cast call --rpc-url https://testnet-rpc.monad.xyz \
  0x0e649C383CFA6be1998445D0A7a8E1cc7540D239 \
  "lastHash(address)(bytes32)" 0xe67e13D545C76C2b4e28DFE27Ad827E1FC18e8D9
# → 0xfe44195b36463e33da7156285383a4fe735093ecadb1abb87684435552814ba9

# 2. Confirm the same hash credited a vault deposit.
cast call --rpc-url https://testnet-rpc.monad.xyz \
  0xC39e298ce89cDfc934c697c9Fe0CC4BAA80B87f5 \
  "deposits(address,bytes32)(uint256)" \
  0xe67e13D545C76C2b4e28DFE27Ad827E1FC18e8D9 \
  0xfe44195b36463e33da7156285383a4fe735093ecadb1abb87684435552814ba9
# → 10000000000000000  (= 0.01 MON)

# 3. Verify the shipped off-chain artefact reconstructs the same hash.
python -c "
import sys, hashlib
sys.path.insert(0,'.')
from src import orders, pq_signing as pq
o = orders.load_signed_orders()[0]
print(hashlib.sha256(pq.canonical_bytes(o.order.to_dict())).hexdigest())
"
# → fe44195b36463e33da7156285383a4fe735093ecadb1abb87684435552814ba9
```

The agent's PQ-signed decision is byte-linked through the off-chain
hash-chain → AuditAnchor → MonadAllocationVault, end-to-end auditable
without trusting the submitter (off-chain leg is Q-Day-resistant;
on-chain leg inherits Monad's ECDSA Q-Day exposure).

**On-chain footprint disclosure.** The shipped state on testnet is one
deployer wallet that has made four anchors (sequences 0–3) and two
vault deposits totalling 0.02 MON. This is an *end-to-end demo*, not a
production system with public users. The pitch is the *provable
composability* of the three-layer chain, not on-chain TPS.

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
- 22 Monad-TX Python tests covering: calldata round trip with shared
  canonicalisation against the PQ-signing layer; transaction field
  shape; bad-address rejection; corruption detection; **AuditAnchor
  calldata selectors verified against `forge inspect`**; **anchor TX
  gas budget under 100 K**; **MONAD_CHAIN_ID locked at 143 (mainnet)**;
  **MonadAllocationVault execute() selector lock-in (`0x4a987805`)**;
  **fractional-weights → uint16 basis-points round-trip sums to 10000**;
  **pool label keccak matches Solidity's hash byte-for-byte**;
  **fractional-weights raises on zero-sum or negative input** so the
  on-chain Allocated event cannot misrepresent agent intent.
- 21 Foundry tests across two contracts:
    * AuditAnchor (8): genesis, chain linking, per-anchorer counter
      isolation, sequence-mismatch revert, zero-hash revert, overload
      coherence, gas budget, 256-run fuzz.
    * MonadAllocationVault (13): execute records & emits event,
      reverts on zero value / zero hash / length mismatch / weights
      sum mismatch, withdraw happy path + insufficient-deposit revert,
      per-user and per-orderHash isolation, naked-send revert,
      reentrancy guard via CEI ordering, gas budget, 256-run fuzz on
      deposit/withdraw invariant.
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
  + 22 Monad-TX Python tests + 21 Foundry tests on two contracts
  (67 total) and produces tamper-evident artefacts that a reviewer can
  audit without running the code. **Both contracts are live on Monad
  testnet** ([AuditAnchor](https://testnet.monadscan.com/address/0x0e649c383cfa6be1998445d0a7a8e1cc7540d239),
  [MonadAllocationVault](https://testnet.monadscan.com/address/0xc39e298ce89cdfc934c697c9fe0cc4baa80b87f5)),
  Monadscan-verified, with a real end-to-end provenance trail already
  on-chain: one PQ-signed agent decision → SHA-256 anchored →
  user-signed 0.01 MON custody deposit, all three artefacts linked by
  the same 32-byte orderHash. Aligned with the NIST FIPS 204 algorithm
  NEAR Protocol committed to at L1 on 2026-05-06 — the first major L1
  to commit to a NIST-finalised PQ signature option at the account
  layer (Q2 2026 testnet rollout planned).
- **Mexico-eligible.** EmpowerTours SAS de CV is incorporated in
  Mexico, qualifying under the LATAM startup criteria.
- **Built honestly.** The code does not claim quantum advantage; the
  backtest does not claim alpha (Sharpe 1.59 vs equal-weight 2.11 on
  the *price-return* walk-forward backtest is reported, not hidden —
  the AI strategy underperforms the naive baseline at this scale,
  which is the honest result of a lookahead-free walk-forward).
  Note: the signed-order's `expected_vol` field is *yield-vol* (the
  annualised standard deviation of daily APY drift on stablecoin /
  staking pools, ≈0.34%), which is intentionally low because these
  are fixed-income-like instruments; the implied per-order Sharpe of
  ≈52 is yield-Sharpe in a Treasuries-like regime, not a price-return
  alpha claim. The price-return Sharpe is the backtest's 1.59 (which
  loses to 1/N — see the honest-framing line above); the on-chain ECDSA gap is documented in
  [`SECURITY.md`](SECURITY.md) as the Q-Day risk we are *preparing for*
  rather than *eliminating*. We avoid the failure mode of pitching
  capabilities the code does not have.

## What would happen with funding

1. **Deploy both contracts on Monad mainnet.** AuditAnchor and
   MonadAllocationVault are already deployed + Monadscan-verified on
   Monad testnet (see addresses above) with 21 Foundry tests passing.
   Mainnet (chainId 143) deployment is gated behind the prize so
   competition funds — not development funds — pay for production
   bytecode. The same `forge script` commands swap `--rpc-url` to
   reach mainnet.
2. **Wire an automated wallet broadcaster** (web3.py + HSM-backed key
   custody) so the agent's `monad_tx.py` output is auto-broadcast on
   a schedule rather than hand-broadcast. Manual broadcast is already
   demonstrated on testnet (anchor TXs sequences 0–3 + two vault
   TXs); the work is automating the broadcast loop and HSM-gating the
   ECDSA signer.
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
