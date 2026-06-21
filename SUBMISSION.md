# Santander X Global Challenge — Quantum AI Leap Submission

## Project: Quantum-Safe DeFi Allocation Agents

Autonomous agents that allocate capital across DeFi yield pools using
hybrid quantum-classical optimisation running on a real IBM Heron QPU,
and sign every rebalance order with post-quantum cryptography so the
audit trail survives the cryptographically relevant quantum era
("Q-Day").

**Repository:** https://github.com/EmpowerTours/quantum-portfolio

**Interactive demo:** https://quantum-portfolio-wni3zpblnnkhktrje9j2wd.streamlit.app/

**81-second walkthrough:** https://github.com/EmpowerTours/quantum-portfolio/blob/main/docs/DEMO_VIDEO.mp4

**License:** MIT
**Applicant:** EmpowerTours SAS de CV (Mexico)
**Application areas:** **Area 3 (primary)** — *Digital Infrastructure
Secured Against Quantum Computing*: a hedged PQ-signed off-chain
order layer with on-chain custody anchoring, live on Monad testnet,
Monadscan-verified, end-to-end reviewer-reproducible. **Area 2
(secondary)** — *Quantum Software and AI-Driven Intelligence*: a
hybrid QAOA + Ridge-regression pipeline running on a real IBM Heron
QPU with honest framing (no quantum advantage at 8 qubits; AI
underperforms equal-weight 1.59 vs 2.11 Sharpe on a lookahead-free
backtest). Area 2 is positioned as *infrastructure ready to scale*
when problem size and shot budget reach the regime where mitigation
lifts become statistically significant; Area 3 is positioned as the
*shippable value* today.

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
| Single-run P(optimal) — raw vs mitigated | 0.293 % → 0.488 % (12 vs 20 successes / 4 096 shots) |
| Wilson 95% CIs (single-run; OVERLAP) | raw [0.16 %, 0.53 %] · mitigated [0.30 %, 0.77 %] |

**Stocks-universe baseline (earlier MVP run, kept for comparison):**

| | |
|---|---|
| Raw job ID | [`d88f7qis46sc73f9cjd0`](https://quantum.ibm.com/jobs/d88f7qis46sc73f9cjd0) |
| Mitigated job ID | [`d88f7sdg7okc73enff00`](https://quantum.ibm.com/jobs/d88f7sdg7okc73enff00) |
| Single-run P(optimal) — raw vs mitigated | 0.537 % → 0.659 % (22 vs 27 successes / 4 096 shots) |
| Wilson 95% CIs (single-run; OVERLAP) | raw [0.35 %, 0.82 %] · mitigated [0.45 %, 0.96 %] |

Both DeFi runs and both stock runs find the **same** optimum as the
classical exact solver, on every method (sim, HW raw, HW mitigated).

**Statistical honesty about the mitigation lift.** Each P(optimal)
above is a single-run frequency (count of optimal-bitstring samples
divided by 4 096 shots). The Wilson 95% CIs overlap for both runs, so
the observed mitigated > raw ordering is a **directional consistency
check**, not a hypothesis-tested significance claim. A Fisher's exact
test on 12 vs 20 successes (DeFi) returns p ≈ 0.16; on 22 vs 27
successes (stocks) p ≈ 0.49. Reaching α = 0.05 significance on lifts
of this magnitude requires either many more shots per run or
replicated independent runs — both shipped as "more compute time" in
the funding line below.

**Methodological precedent (NOT a transitive significance claim).** A
February-2026 study on IBM Torino/Fez (Heron family) reported a
statistically significant +31.6 % improvement on a portfolio QUBO,
with p = 0.0009 and Cohen's d = 2.01, **at 88 qubits with zero-noise
extrapolation across seven independent hardware runs** ([arXiv 2602.09047](https://arxiv.org/abs/2602.09047)).
Their stack (ZNE), scale (88 qubits), and replication (n=7) differ
from ours (XY4 DD + twirling, 8 qubits, n=1), so their p-value does
not transfer. We cite it as **methodological precedent that hardware
error mitigation on portfolio-style QUBOs on Heron can produce
significant lifts when properly powered** — the same direction we
ship as a single-run consistency check, scaled-down.

**Honest framing baked into the app:** at 8-qubit scale the classical
exact solver beats both QPU runs in wall-clock time. The value
demonstrated is the *hybrid pipeline*, the *cohesion* between the pitch
and the hardware, and the *directional consistency* of an error-
mitigation effect under-powered to claim significance at this scale —
**not quantum advantage** (not claimed) and **not a tested lift**
(would need ≳10× shots or replicated runs). Both honest limitations
are documented so a panel reviewer running the math gets the same
answer we put in the table.

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

**Discovery note → resolution.** Initial discovery rounds (GeckoTerminal,
MonadVision, MCP-MONI config, mainnet Uniswap V3 deterministic
addresses, Uniswap-deployer's actual CREATE2 outputs, Kuru's official
`docs.kuru.io/contracts/Contract-addresses`, LFJ's `developers.lfj.gg`,
Bean Exchange's documented router) returned **zero working DEX
contracts** on the current Monad testnet — every canonical address
listed in ecosystem docs has empty bytecode on the live RPC across
four independent RPC providers (Monad official, thirdweb, Ankr,
dRPC). The testnet appears to have been reset around 2025-12-16
and ecosystem documentation has not caught up; most teams have
migrated to Monad **mainnet** (live since November 2025, chainId 143)
where the 0x Swap API aggregates Kuru, Crystal, Clober, OctoSwap,
Atlantis, IziSwap, Intro, Morpheus, LFJ, and Uniswap.

Rather than block on the testnet ecosystem catching up, we deployed
**our own minimal Uniswap V2-style AMM stack** on Monad testnet so
the agent → routed-trade flow is provable end-to-end today. The full
six-contract deployment is described in the next section.

### Real on-chain trade execution — `RoutingVault` + MiniAMM

Six new contracts deployed and Monadscan-verified on Monad testnet:

| Contract | Address | Role |
|---|---|---|
| `WMON` | [`0x9eb31580…975aa`](https://testnet.monadscan.com/address/0x9eb31580dbc752629c50b9773ee6e5e03b5975aa) | ERC20 wrap of native MON (WETH9-pattern) |
| `mUSDC` | [`0x0478bf31…fae87`](https://testnet.monadscan.com/address/0x0478bf311832ffebc87d9f9294e4414208ffae87) | Test stablecoin (18 decimals, public faucet) |
| `mUSDT` | [`0x6e353e7a…d1574`](https://testnet.monadscan.com/address/0x6e353e7ac67a9fb410a7a6c3d9df474a561d1574) | Test stablecoin (18 decimals, public faucet) |
| `MiniAMM` (WMON/mUSDC) | [`0xef1cf616…e359a`](https://testnet.monadscan.com/address/0xef1cf6164ab0793a7a42740153807269726e359a) | Constant-product AMM, **canonical V2 0.3% fee**, V2-style swap events, ReentrancyGuard, `skim()` |
| `MiniAMM` (WMON/mUSDT) | [`0xca4f1118…3e159`](https://testnet.monadscan.com/address/0xca4f1118533266af41e426d96992d3833dc3e159) | Same |
| `RoutingVault` | [`0x70580f77…e6938`](https://testnet.monadscan.com/address/0x70580f77d7602f9a03fd34f17f3cc395bbce6938) | Agent-driven swap executor (hardened: anchor-existence check, pair allowlist, ReentrancyGuard, `amountOutMin` from caller, post-loop WMON-balance invariant, `Routed` event) |

`RoutingVault.executeAndRoute(orderHash, tokenOuts[], pairs[], weightsBps[], minOuts[])`
is `payable`: the caller sends MON; the vault wraps to WMON, splits
by weight, routes each portion through the requested AMM pair with
explicit per-pool slippage protection, transfers output tokens to
`msg.sender`, and emits a `Routed(user, orderHash, amountIn,
tokenOuts, amountsOut, weightsBps)` event linking the on-chain trade
back to the agent's PQ-signed off-chain order.

`MiniAMM` is a fresh implementation of Uniswap V2's `x*y = k` AMM
math under `solc 0.8.28` (V2's reference contracts target 0.5.x).
The constant-product invariant, the 0.3 % fee, the `Swap`/`Sync`/
`Mint`/`Burn` event shapes, and the LP-token bookkeeping match V2;
the contract surface is intentionally smaller (one pair per
deployment, no flash loans, no callbacks) because the demonstration
target is the agent → vault → pair flow, not full DEX functionality.

**End-to-end demonstrated on testnet — 0.1 MON → 115.64 mUSDC + 115.64 mUSDT:**

| Step | Contract | TX | Effect |
|---|---|---|---|
| 1. Anchor `orderHash` (seq 6) | AuditAnchor | [`0x2c087831…54c1`](https://testnet.monadscan.com/tx/0x2c0878319c5dfabff83761ada36ba7c425f238394d1656f63ccc9da0d8c154c1) | `0xca148bff…581b` anchored, prevHash = seq 5 |
| 2. `executeAndRoute(0.1 MON, [mUSDC, mUSDT], 50/50, amountOutMin=[117.52, 117.52])` | RoutingVault (hardened v3) | [`0x5e426661…ede4`](https://testnet.monadscan.com/tx/0x5e426661ef372e97fdc61fc04cc2fbc251aa5aab4646b77405cf6e07cfa6ede4) | 2× `MiniAMM.Swap` events + 1 `RoutingVault.Routed` event (renamed from `Allocated` to avoid event-name collision with `MonadAllocationVault`). Caller-supplied `amountOutMin` goes directly to `pair.swap` — sandwich-resistant (the on-chain quote-then-swap pattern from the prior deploy was vulnerable). **117.52 mUSDC + 117.52 mUSDT delivered** (= `amountOutMin`; the 0.99-token surplus vs the spot V2 quote stays in reserves, which is the V2-spec behavior for `amountOutMin`-driven swaps). |

The on-chain provenance trail is now **four steps deep, byte-linked
end-to-end**: shipped `outputs/signed_orders.json` →
`AuditAnchor.lastHash[wallet]` → `RoutingVault.Routed` event →
two `MiniAMM.Swap` events, all from the same wallet `0xe67e…e8D9`,
all referencing the same 32-byte orderHash, all reviewer-verifiable
via `cast call` without trusting us. Production deployments swap
`RoutingVault` for a successor that calls the live Kuru / Uniswap
router on Monad mainnet — the agent-facing event shape stays
identical so historical orders remain replayable across upgrades.

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
| 1. Anchor `orderHash` on-chain (sequence 3) | AuditAnchor | [`0x60d32b16…2da8e`](https://testnet.monadscan.com/tx/0x60d32b1610dfb28a630dd8f4a64d9c6a9bc4fa4ef2a99700f69c4ef84e62da8e) | 47 061 |
| 2. Escrow `0.01 MON` under `orderHash` | MonadAllocationVault | [`0x7be13153…18ef66`](https://testnet.monadscan.com/tx/0x7be13153bd7103d4cdbba3edd7ea4593a6e9579a69ca25a9790f0cbe6f18ef66) | 71 476 |

(Sequence 3 is the *currently shipped* anchor — the seq 0/1/2
anchors listed in the deploy table above are earlier demos; each
regen of the signed order produces a new orderHash and the agent
re-anchors. The chain link in the new anchor's `prevHash` field
equals the seq-2 anchor's orderHash, so the on-chain JSONL-mirroring
chain is intact across all four anchors.)

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

## Post-deploy regression discipline (what we did about the fee bug)

The mini-DEX shipped with `FEE_BPS = 30` declared as a constant — a
naming choice that *should* have meant 0.30 % in basis points, but
the AMM math actually treated it as per-mille, producing **3 %**
real fee on every swap (10× the V2 default). The bug shipped, was
deployed to testnet, executed real swaps, and was caught by a
hands-on math check against V2's exact formula. The story matters
because **a panel reviewer who knows DeFi will ask "you shipped a 10×
error on the most-tested constant in DeFi — what other 10× bugs are
in code you didn't catch?"**, and the answer is regression discipline,
not reassurance.

Three things we did about it:

1. **Renamed the constant + fixed the value** — `FEE_PER_MILLE = 3`,
   value matches V2 canonical 0.3 %. Math left identical.
2. **Wrote the test that should have existed before deploy.**
   `test_QuoteMatchesCanonicalV2Formula` (`contracts/test/RoutingVault.t.sol`)
   asserts the on-chain `quoteToken1Out` return value equals the
   hand-computed V2 formula `(amountIn × (1000 − feePerMille) × reserveOut) ÷ (reserveIn × 1000 + amountIn × (1000 − feePerMille))`
   **bit-for-bit**, and asserts `FEE_PER_MILLE == 3`. A future change
   that drifts either the constant or the formula fails this test
   before deploy.
3. **Added a constant-product k-invariant test.** `test_KInvariantStrictlyGrowsAfterSwap`
   asserts `k = r0 × r1` *strictly grows* after every swap (the fee
   stays in the reserves). If k ever shrinks, the AMM is leaking
   value — that test would catch it.

The pattern generalises: **every load-bearing on-chain constant
should have a "this is what canonical means, bit-for-bit" test that
the deploy pipeline runs**, not a docstring claim that the audit
might catch. Funded line item #1 of the funding section pays for
that pattern to be applied across the contract surface, not just
the AMM fee.

What was NOT caught at deploy and shipped on the first MiniAMM is
preserved as a paper trail at [`0xabe750f9…7e15e`](https://testnet.monadscan.com/address/0xabe750f9de36d69d41aaf8f20da097fb67f7e15e)
(buggy WMON) and [`0xee83ac7e…2ec87`](https://testnet.monadscan.com/address/0xee83ac7e916f4febdb7297363b47ee370fe2ec87)
(buggy 3%-fee pair). These contracts still execute swaps; users
calling them get 3 % fee instead of 0.3 %. They are **not** the
contracts cited in the active provenance trail. We retain them on
Monadscan as evidence of the bug-fix process, not for active use.

## Test coverage and CI

- 28 PQ-signing tests covering: variant lock-in for SLH-DSA-SHAKE-256s;
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
- 23 Monad-TX Python tests covering: calldata round trip with shared
  canonicalisation against the PQ-signing layer; transaction field
  shape; bad-address rejection; corruption detection; **AuditAnchor
  calldata selectors verified against `forge inspect`**; **anchor TX
  gas budget under 100 K**; **MONAD_CHAIN_ID locked at 143 (mainnet)**;
  **MonadAllocationVault execute() selector lock-in (`0x4a987805`)**;
  **fractional-weights → uint16 basis-points round-trip sums to 10000**;
  **pool label keccak matches Solidity's hash byte-for-byte**;
  **fractional-weights raises on zero-sum or negative input** so the
  on-chain Allocated event cannot misrepresent agent intent.
- 33 Foundry tests across three test suites:
    * AuditAnchor (8): genesis, chain linking, per-anchorer counter
      isolation, sequence-mismatch revert, zero-hash revert, overload
      coherence, gas budget, 256-run fuzz.
    * MonadAllocationVault (13): execute records & emits event,
      reverts on zero value / zero hash / length mismatch / weights
      sum mismatch, withdraw happy path + insufficient-deposit revert,
      per-user and per-orderHash isolation, naked-send revert,
      reentrancy guard via CEI ordering, gas budget, 256-run fuzz on
      deposit/withdraw invariant.
    * RoutingVault (12): happy-path routing, slippage reverts,
      anchor-existence guard, pair allowlist, token/pair validation,
      naked-send rejection, event payload, WMON dust recovery guard,
      canonical V2 quote formula, and k-invariant growth after swap.
- GitHub Actions runs the Python suite on Python 3.11 and 3.12 on every
  push, plus an import smoke test of every source module on top of the
  full `requirements.txt`. Audit-chain verification of the shipped
  `outputs/audit_log.jsonl` runs as a separate CI step. Foundry tests
  are run locally with `cd contracts && forge test`.

## Why this fits the challenge

- **Area 3 (primary) — Digital Infrastructure Secured Against Quantum
  Computing.** The PQ signing layer is not narrative — it is verified
  by 28 PQ tests + 23 Monad-TX Python tests + 33 Foundry tests
  (84 total) and produces tamper-evident artefacts that a reviewer can
  audit without running the code. **AuditAnchor, MonadAllocationVault,
  and the RoutingVault mini-DEX stack are live on Monad testnet**
  ([AuditAnchor](https://testnet.monadscan.com/address/0x0e649c383cfa6be1998445d0a7a8e1cc7540d239),
  [MonadAllocationVault](https://testnet.monadscan.com/address/0xc39e298ce89cdfc934c697c9fe0cc4baa80b87f5),
  [RoutingVault](https://testnet.monadscan.com/address/0x70580f77d7602f9a03fd34f17f3cc395bbce6938)),
  Monadscan-verified, with a real end-to-end provenance trail already
  on-chain: one PQ-signed agent decision → SHA-256 anchored →
  user-signed 0.01 MON custody deposit, all three artefacts linked by
  the same 32-byte orderHash. Aligned with the NIST FIPS 204 algorithm
  NEAR Protocol committed to at L1 on 2026-05-06 — the first major L1
  to commit to a NIST-finalised PQ signature option at the account
  layer (Q2 2026 testnet rollout planned).
- **Area 2 (secondary) — Quantum Software and AI-Driven Intelligence.**
  The pipeline runs today on a single workstation; the QPU portion
  runs today on `ibm_marrakesh`. Nothing waits for fault-tolerant
  hardware. Our XY4 DD + gate/measurement twirling stack is the same
  direction — NISQ Heron + mitigation on a finance QUBO — demonstrated
  to give a significant lift in a concurrent **larger-scale, properly-
  powered** February 2026 study (arXiv 2602.09047, 88 qubits, ZNE,
  n=7 hardware runs). **Their p-value does not transfer to our
  single 4 096-shot run** — see the methodological-precedent /
  statistical-honesty disclaimers in the hardware-execution section
  above; we ship directional consistency, not a tested lift.
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
  are fixed-income-like instruments where volatility lives in *yield
  drift* (small day-to-day APY fluctuation), not in *token price*;
  the implied per-order Sharpe of ≈52 is yield-Sharpe in a
  Treasuries-like regime, not a price-return alpha claim. The price-return Sharpe is the backtest's 1.59 (which
  loses to 1/N — see the honest-framing line above); the on-chain ECDSA gap is documented in
  [`SECURITY.md`](SECURITY.md) as the Q-Day risk we are *preparing for*
  rather than *eliminating*. We avoid the failure mode of pitching
  capabilities the code does not have.

## What would happen with funding

Ordered from highest-leverage credibility uplift to lowest-leverage
capability extension. The mainnet deploy is genuinely the *last*
item, not the first — gas is trivial; what mainnet credibly needs is
the audit + bounty steps below.

1. **Commission a security audit by a reputable firm.** Trail of Bits,
   OpenZeppelin, Spearbit, ConsenSys Diligence, Cyfrin, Zellic — or an
   audit firm of comparable reputation — on the full stack:
   AuditAnchor.sol + MonadAllocationVault.sol + `src/pq_signing.py`
   canonicalisation + `src/orders.py` audit-chain + `src/monad_tx.py`
   ABI encoders. Engagement budget: **$50–200K** depending on scope
   and timeline. Output: a public audit report referenced from this
   repo's README.

2. **HSM-backed agent custody.** Move the ML-DSA / SLH-DSA / Ed25519
   secret keys from chmod-600 files into AWS KMS / GCP Cloud HSM /
   Yubico Hardware Security Module so the agent's signing keys cannot
   be exfiltrated by a local-FS attacker. **This step must precede the
   bounty below** — exposing chmod-600 keys to a public-bounty crowd
   would be malpractice; the HSM moves the secret out of the
   bounty-attack surface so the bounty exclusively tests the protocol,
   not the operator's machine. Wire web3.py + the same HSM for the
   ECDSA wallet, automating the broadcast loop.

3. **Stand up a paid bug bounty.** Immunefi or Code4rena listing with
   a tiered payout ($25–100K for criticals on either contract or the
   off-chain signing path, smaller bounties on the audit-chain
   integrity). Six months runway before mainnet deploy is the goal.
   Sequenced after the HSM step so the bounty surface is the
   protocol, not the operator's filesystem.

4. **Multi-oracle data-integrity layer.** Replace the unauthenticated
   DeFiLlama feed with a multi-source consensus (Pyth + Chainlink +
   on-chain pool reads from Morpho / Upshift / Neverland / shMONAD
   directly) so the agent's QUBO input is signed-and-verifiable, not
   trusted REST. This is the largest *engineering* line item —
   roughly 2 engineer-months — and the one that turns Area-3
   compliance from defensible to institutional-grade.

5. **Statistical power on the QPU runs.** Move from 4 096 shots × 1
   run to 4 096 shots × ≥10 independent runs, on both raw and
   mitigated, so a paired hypothesis test reaches α = 0.05 (or
   reveals that the directional lift we currently observe is noise —
   either result is a useful update). Re-run on multiple Heron
   backends to control for hardware drift. IBM Quantum compute time
   is the cost driver here, not engineer time.

6. **Mainnet deployment.** AuditAnchor + MonadAllocationVault redeploy
   on Monad mainnet (chainId 143), exact same `forge script` with
   `--rpc-url https://rpc.monad.xyz`. Cost: ~$50 of MON. Trivial vs
   the audit/bounty line items above — but only credibly defensible
   *after* the security audit has signed off on the source.

7. **Capability registry (signature ≠ capability).** The current PQ
   signature proves *who* signed an order; it does not prove the
   signer is *authorised* to allocate $X to pool Y. A capability
   registry contract on Monad (issuer → agent → max-allocation
   per pool, time-bounded) closes this gap. Specification work,
   then a third contract deployed alongside AuditAnchor + Vault.

8. **Track FIPS 206 (FN-DSA / Falcon).** NIST has not finalised the
   standard as of mid-2026 — projected late 2026 / early 2027. When
   the spec freezes, add Falcon as a fourth hedge with the smallest
   signature size for the on-chain hash-anchor calldata path.

9. **Scale the backtest** to multi-year history and 50+ pools (current
   MVP is 8 stocks / 8 pools, 48 monthly rebalances). Swap in
   gradient-boosted ensembles / structured-news Ridge / a learned
   per-pool risk model — anywhere the Ridge baseline currently loses
   to 1/N is a candidate. The pipeline is component-agnostic.

10. **Cryptographic agility ground-up.** Bind a `crypto_suite_id`
    integer into the signed payload (already supported via
    `schema_version`) so future migrations to e.g. ML-DSA-87 or
    FN-DSA-512 are zero-downtime — same audit log, additive scheme
    versions, no key reuse across schemes.

## Reproducing the artefacts

There are **two valid review paths** — choose based on whether you want
to confirm the shipped state matches the on-chain anchors (Path A) or
exercise the full pipeline from scratch (Path B). They produce
different outputs by design.

### Path A — verify the shipped state against the on-chain anchors

This is what the `cast call` block in the on-chain-anchor section above
walks through, end-to-end. You do **not** need to run `run_pq_demo.py`.
The shipped `outputs/signed_orders.json` contains the order whose
canonical SHA-256 is `0xfe44195b…14ba9`, and the on-chain
`AuditAnchor.lastHash[deployer]` returns the same hash. Every Foundry
+ Python test passes against the shipped repo.

```sh
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python tests/test_pq_signing.py
python tests/test_monad_tx.py
( cd contracts && forge test )

# Re-derive the canonical-bytes digest of the shipped order:
python -c "
import sys, hashlib; sys.path.insert(0,'.')
from src import orders, pq_signing as pq
print(hashlib.sha256(pq.canonical_bytes(orders.load_signed_orders()[0].order.to_dict())).hexdigest())
"
# Expected: fe44195b36463e33da7156285383a4fe735093ecadb1abb87684435552814ba9
```

### Path B — exercise the pipeline from scratch (new keys, new TXs)

`run_pq_demo.py` generates a **fresh keypair** (if `keys/` is empty),
a fresh UUID4 nonce, and a fresh ISO-8601 timestamp on every run, so
every regen produces a **new orderHash that will not match our
shipped anchors**. **Path B overwrites `outputs/signed_orders.json`
and `outputs/unsigned_*.json`, and appends a new entry to
`outputs/audit_log.jsonl`** — back these files up first if you want to
re-run Path A's hash comparison afterwards. To anchor + escrow your
fresh order on Monad testnet you'd broadcast new anchor + vault TXs
yourself (requires testnet MON — get some from the official faucet at
https://testnet.monad.xyz); the existing contracts accept any new
orderHash, advancing your own per-wallet sequence counter
independently of ours.

```sh
# 1. Run the QAOA on real hardware (needs IBM_QUANTUM_TOKEN in .env)
python run_hardware.py
python run_hardware.py --universe defi   # live DeFiLlama pools

# 2. Sign the resulting order under your own fresh keys
python run_pq_demo.py
# → outputs/signed_orders.json    (NEW orderHash, NOT the shipped one)
# → outputs/audit_log.jsonl       (NEW chain entry under YOUR keys)
# → outputs/unsigned_anchor_tx.json + unsigned_alloc_tx.json (wallet-ready)

# 3. Optional: broadcast the unsigned TXs yourself (testnet)
cast send --rpc-url https://testnet-rpc.monad.xyz --private-key $YOUR_KEY ...

# 4. UI
streamlit run app.py
```

Path B is for evaluating the *pipeline*; Path A is for verifying *our
shipped artefact* matches *our shipped on-chain anchors*. Both are
valid; mixing them (e.g., running B then asserting your fresh
orderHash matches A's `lastHash`) will fail by design — that's the
**expected divergence** that confirms your fresh-keys regen actually
produced a new order, not a re-derivation of ours.

## Contact

GitHub issues at https://github.com/EmpowerTours/quantum-portfolio
