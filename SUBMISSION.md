# Santander X Global Challenge — Quantum AI Leap Submission

## Project: Quantum-Safe DeFi Allocation Agents

Autonomous agents that allocate capital across DeFi yield pools using
hybrid quantum-classical optimisation running on a real IBM Heron QPU,
and sign every rebalance order with post-quantum cryptography so the
audit trail survives the cryptographically relevant quantum era
("Q-Day").

**Repository:** https://github.com/EmpowerTours/quantum-portfolio

**Interactive demo:** https://quantum-portfolio-awhfbfwtbqmp2swgpsvxwf.streamlit.app/

**81-second walkthrough:** https://github.com/EmpowerTours/quantum-portfolio/blob/main/docs/DEMO_VIDEO.mp4

**License:** MIT
**Applicant:** EmpowerTours SAS de CV (Mexico)
**Application areas:** **Area 3 (primary)** — *Digital Infrastructure
Secured Against Quantum Computing*: a hedged PQ-signed off-chain
order layer with on-chain custody anchoring, **executed on Monad
mainnet with real value** (chainId 143, both contracts Monadscan-
verified — see "Now live on Monad mainnet" below) as well as testnet,
end-to-end reviewer-reproducible. **Area 2
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
`src/qaoa_hw.py:140-148`).

**Verifiability.** Qiskit Runtime job results are scoped to the owning IBM
account, so a job ID alone is *not* third-party verifiable — an earlier
revision claimed the runs were "verifiable on quantum.ibm.com", which a
reviewer clicking the link would have found untrue. The raw measurement
counts are therefore shipped inside `outputs/hardware_run_defi.json`, so
P(optimal), the feasible fraction and the approximation ratio can all be
recomputed from the artefact without an IBM account. `backfill_counts.py`
re-derives them from the job IDs and asserts they match what is stored.

**DeFi-pool universe — XY-mixer run, ibm_marrakesh, reps=3, ring topology:**

| | sim | hw raw | hw mitigated |
|---|---|---|---|
| Job ID | — | `d9mobuvurbec73e654n0` | `d9moep7urbec73e657tg` |
| P(optimal) | 0.0266 | **0.0054** | **0.0054** |
| Feasible fraction | 100.0 % | **33.5 %** | **35.6 %** |
| Mean approximation ratio | 0.168 | 0.066 | 0.029 |
| Two-qubit gates (transpiled) | — | 288 | 272 |
| Distinct states sampled | — | 255 | 254 |

Baselines: uniform random over 2⁸ bitstrings gives P(optimal) =
**0.00391** and a feasible fraction of
**21.9 %** (C(8,3)/2⁸). Uniform over *feasible* states gives
**0.01786**.

**What this run does and does not show.** Two axes, and they say different
things — the distinction matters and we state it rather than average over it.

*The constraint structure partially survived.* The XY mixer conserves Hamming
weight by construction, so a fully decohered circuit returns the random
feasible rate of C(8,3)/2⁸ = **21.9 %** and a perfect one returns 100 %. We
measured **33.5 %** (raw) and **35.6 %** (mitigated). That is real, and it is
the first evidence in this project that circuit structure survived the device.

*The optimisation signal did not.* Conditioned on landing in the feasible
subspace, P(optimal | feasible) is **0.0161** raw and **0.0151** mitigated,
against uniform-over-feasible of 1/C(8,3) = **0.0179** — i.e. **0.90× and
0.84×, at or slightly below random**. So within the states it produced, the
circuit expressed no preference for good portfolios. The unconditional
P(optimal) of 0.00537 clears the uniform 2⁸ null of 0.00391 (×1.38) *only
because the mixer biases towards feasible states at all*, not because it
found better ones.

The honest summary: **the XY mixer works and the optimisation does not
survive 288 two-qubit gates on today's hardware.** That is a sharper and more
useful result than the previous penalty-mixer run, which returned P(optimal)
0.00366 against a 0.00391 null — indistinguishable from noise on every axis,
with no diagnostic capable of telling us why. We can now say precisely which
component failed.

Error mitigation again shows nothing: identical P(optimal) to five decimal
places, a *lower* mean approximation ratio, and a lower P(optimal | feasible).
We make no mitigation claim.

**Evidence artefacts.** `docs/screenshots/07-ibm-job-records.png` is a live
Qiskit Runtime API record of both jobs (status, backend, timestamps, QPU
seconds, shot counts), retrieved at the time of writing.
`docs/screenshots/08-hardware-vs-noise.png` plots both metrics against both
null baselines and is regenerable by anyone with
`python make_hardware_chart.py`. Neither is a substitute for the raw counts —
those are the artefact a reviewer should actually check.

**Which run is on chain.** The order settled on Monad mainnet
(`orderHash 0xd8bf1551…15f9`) cites `qpu_job_id d9loj33hdfks73cl9in0` — the
**earlier penalty-mixer run**, archived at
`outputs/hardware_run_defi_penalty_anchored.json` so that job ID still
resolves. The XY run above is newer and better but is **not** the one that was
anchored, swapped, supplied and ZK-attested; re-threading it to chain would
mean a fresh signed order, a fresh anchor and a fresh Groth16 proof. Both runs
select the same three pools (Morpho STEAKETH · Neverland USDC · shMONAD), so the
*decision* is unchanged — only the circuit that produced it improved.

**Why the XY mixer, and what it cost.** The original path enforced the budget
as a quadratic penalty over the full 2ⁿ space. `src/xy_qaoa.py` instead starts
in a feasible state and mixes with an XY interaction that conserves Hamming
weight, so the budget holds by construction. Measured on the stocks universe
against a uniform-over-feasible null of 0.0179:

| configuration | simulator P(opt) | 2Q gates (FakeMarrakesh) |
|---|---|---|
| penalty, reps=2 | 0.00098 | 228 |
| XY complete, reps=2 | **0.0000** — collapses to one basis state | — |
| XY complete, reps=6 | 0.0808 | 1572 |
| **XY ring, reps=3** | **0.2078** | **454** |

Two findings worth stating because they are not obvious. At **reps=2 the XY
path fails completely**: the optimiser minimises ⟨H⟩ by rotating
deterministically onto a single suboptimal basis state, giving 100 %
feasibility and P(optimal) = 0. `run_hardware.py` now refuses `--reps < 3`
with that explanation. And the **ring topology beats the complete graph on
both axes** — 2.6× the P(optimal) at 29 % of the gate count — because
all-to-all XY routes badly on heavy-hex connectivity. The complete graph was
hardcoded; nothing on hardware would have revealed either of these, and
running the default would have produced a guaranteed zero.

**Stocks universe — XY-mixer run, ibm_fez, reps=3, ring topology.
This is the strongest quantum result in the project and the only statistically
significant one.**

| | sim | hw raw | hw mitigated |
|---|---|---|---|
| Job ID | — | `d9n20fmij12s73ftcat0` | `d9n20h8qs0bc73e2tlog` |
| Optimal found | 899 / 4096 | **13 / 4096** | **39 / 4096** |
| P(optimal) | 0.2195 | 0.0032 | 0.0095 |
| Feasible fraction | 100.0 % | 23.4 % | 24.3 % |
| **P(optimal \| feasible)** | **0.2195** | **0.0136** | **0.0392** |
| vs uniform-over-feasible (1/56) | **×12.3** | ×0.76 | **×2.19** |
| Mean approximation ratio | 0.711 | 0.034 | 0.106 |
| Two-qubit gates | — | 498 | 489 |

**Error mitigation is what makes the signal survive, and the effect is
significant.** The raw arm found the optimum 13 times in 4 096 shots — a
conditional rate of 0.0136 against a uniform-over-feasible baseline of
1/C(8,3) = 0.0179, i.e. **below chance, indistinguishable from noise**. The
mitigated arm (XY4 dynamical decoupling + gate and measurement twirling) found
it **39 times, ×2.19 above that baseline**. Fisher's exact test on 13 vs 39
successes out of 4 096 each returns **p = 0.00039**.

**Scope of that claim, stated precisely.** The Fisher test compares two
binomial samples and is valid for *these two runs*: within this pair, the
mitigated arm is significantly better. It does **not** establish an effect size
that replicates, because n = 1 per arm — run-to-run calibration drift is not
captured. The honest statement is *"in a matched pair on ibm_fez, error
mitigation moved a null result to a significant one (p = 0.0004)"*, not
*"mitigation reliably yields 3×"*. Replication (n ≥ 10) is the milestone that
would upgrade it, and it is funded work, not a claim made here.

Note this **contradicts the DeFi run above**, where mitigation showed no effect
at all. The plausible reason is circuit depth — the stocks circuit is
498 two-qubit gates against the DeFi run's 288, and
dynamical decoupling has more idle time to protect. With n = 1 on each we
report the discrepancy rather than explain it away.

**Why stocks and not DeFi.** The same method, the same mixer, the same depth
regime, and a 12.3× versus 1.5× simulator result. Equities genuinely co-move,
so the covariance term is commensurate with returns and the QUBO has real
quadratic structure. DeFi yields barely correlate: the covariance entries are
~10⁻⁸ against returns of ~10⁻², so that instance degenerates towards a
cardinality-constrained sort — solvable by `sorted(mu)[-3:]`, with almost
nothing for a quantum algorithm to do. We tested raising `risk_factor` to
force structure (0.5 → 50 000) and it made things monotonically **worse**
(1.5× → 0.1× → 0.0×): amplifying a numerically tiny covariance produces a
rugged, ill-conditioned landscape rather than a richer one. That experiment is
reported because it failed.

Both DeFi runs and both stock runs find the **same** optimum as the
classical exact solver, on every method (sim, HW raw, HW mitigated).

**Statistical honesty about the mitigation lift.** Every P(optimal) above is
a single-run frequency over 4 096 shots, n = 1 per arm. The two universes
disagree and we report both rather than the flattering one:

* **Stocks** (`ibm_fez`, 498 two-qubit gates): 13 → 39 successes, Fisher exact
  **p = 0.00039**. A real, significant effect *within this pair of runs*.
* **DeFi** (`ibm_marrakesh`, 288 gates): 22 → 22 successes, **p = 1.000**. No
  effect whatsoever.

n = 1 per arm means neither result establishes a replicating effect size —
run-to-run calibration drift is uncaptured, and a significant Fisher test on
one matched pair is not the same as a reproducible lift. Reaching a defensible
effect size needs n ≥ 10 independent runs per arm, which is funded work rather
than a claim made here. The plausible explanation for the disagreement is
depth — dynamical decoupling has more idle time to protect at 498 gates than
at 288 — but with a single run each we state that as a hypothesis, not a
finding.

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
Solidity verifier would cost an estimated ~500 M gas (literature figure, not measured by us)
([hackernoon 2026](https://hackernoon.com/comparing-on-chain-post-quantum-signature-verification-for-ethereum)).
Anchoring the digest, not the signature, is the cost-feasible cell in
the off-chain-PQ × on-chain-classical design space — and remains
useful even after EVM chains adopt native PQ signatures.

**Test coverage** (Foundry, `forge test`): 8 tests — genesis prev_hash,
chain linking, per-anchorer counter isolation, sequence-mismatch revert,
zero-hash revert, overload coherence, gas budget assertion (`<60 K`),
and a 256-run fuzz on arbitrary 32-byte digests. All pass against
`solc 0.8.28`.

**Deployment status — Monad testnet (chainId 10143), the original deployment** (the production redeploy is in "Now live on Monad mainnet" below):

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
| On-chain chain link | Second TX's `prevHash` data field == first TX's `orderHash` topic, so the on-chain event sequence reproduces the off-chain JSONL ordering. **Scope:** `prev_hash` is written by the logger and is not inside the PQ-signed payload, so this links the two records but does not cryptographically bind them — a holder of the log could rewrite the ordering without invalidating any signature. Each individual order's *contents* remain signature-protected. |

The first anchor pays a one-time cold-SSTORE penalty (two zero→nonzero
writes for `nextSequence` and `lastHash`). Steady-state cost is **47 K
gas per anchor** — within the ~30 K function-body budget once base TX
+ warm SSTORE costs are accounted for. Both events are reconstructable
by any indexer filtering `Anchored(address indexed, bytes32 indexed,
uint64 indexed, bytes32)` on the verified contract address.

### Now live on Monad mainnet — the full loop, executed with real value (2026-07-12)

The testnet artefacts above prove the mechanism. On **2026-07-12 we
deployed the production stack to Monad mainnet (chainId 143) and ran
the entire quantum → PQ-signed order → on-chain anchor → real DEX swap
loop with real MON**, from deployer wallet
`0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1`. Both contracts are
Monadscan-verified (source + ABI public):

| | Address (Monadscan-verified) |
|---|---|
| **AuditAnchorV2** (mainnet) | [`0x8422b555DCE11913A4657C2f47C839637FC71ffd`](https://monadscan.com/address/0x8422b555dce11913a4657c2f47c839637fc71ffd) |
| **UniswapRoutingVault** (mainnet) | [`0x06F233062eE23590e5CC873df511024f3d981e56`](https://monadscan.com/address/0x06f233062ee23590e5cc873df511024f3d981e56) |
| **MorphoSupplyAdapter** (mainnet) | [`0x8d5AE2f23E5d20bFb7915168d6b2a3Ce753fE49E`](https://monadscan.com/address/0x8d5ae2f23e5d20bfb7915168d6b2a3ce753fe49e) |

<details>
<summary>Superseded 2026-07-30 (the first deployment, still on chain)</summary>

`AuditAnchor` [`0x4cb79cc3…a27c`](https://monadscan.com/address/0x4cb79cc36b367a6fd7363bc6a8553a7a270da27c),
`UniswapRoutingVault` [`0xe2fcada0…16dd`](https://monadscan.com/address/0xe2fcada067227c817b8a47b850d727ba065e16dd),
`MorphoSupplyAdapter` [`0xB1a43414…5958`](https://monadscan.com/address/0xB1a4341403DA395760561B85C4C96696C0D15958),
`MLDSAAttestation` [`0xc1a82D8C…3839`](https://monadscan.com/address/0xc1a82D8C4D28Eca8B318D1bac8DCc2Ab963b3839).

A security audit found that V1's authorisation slot, `lastHash[anchorer]`,
recorded only *that* an anchorer had approved *something*. Any execution by
that address satisfied it, so the anchor proved an order existed rather than
that this specific trade was authorised. `AuditAnchorV2` replaces it with
`execCommitmentOf[user][orderHash]`, a commitment over the exact executor,
chain, tokens, fee tiers, weights, amount, slippage floors and deadline. The
executors recompute it from their own calldata and revert on any divergence.

All four superseded contracts hold zero of every asset; nothing was migrated.

</details>

Unlike the testnet `RoutingVault` (which routed through our own
`MiniAMM` because no DEX existed on testnet), the mainnet
`UniswapRoutingVault` swaps through **production Uniswap v3**
(SwapRouter02 `0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900`), which went
live on Monad mainnet on 2025-11-24. Its `amountOutMin` is a true
per-leg floor, it carries a `deadline`, an immutable approved-token
allowlist (frozen to `[USDC]` at deploy), an immutable fee-tier allowlist
(frozen to `[3000]`, the only WMON/USDC pool with real depth), and an anchor
gate on `ANCHOR.execCommitmentOf[msg.sender][orderHash]`.

**The real-value proof loop, re-executed 2026-07-30 against the V2 contracts**
(all reviewer-verifiable on Monadscan):

| Step | Contract | TX | Effect |
|---|---|---|---|
| 1. Anchor the **routing** commitment | AuditAnchorV2 | [`0x8702d6a9…d40a7d`](https://monadscan.com/tx/0x8702d6a99fa070ed97032e73351e7167f8ef278da20b7b9ce3d1730866d40a7d) | sequence 0; orderHash `0xd8bf1551…15f9` = SHA-256 of a hedged ML-DSA + SLH-DSA + Ed25519 signed order, with a commitment binding the vault, chain, token, fee tier, weights, amount, slippage floor and deadline |
| 2. `executeAndRoute(0.1 MON → USDC)` | UniswapRoutingVault | [`0xf3696f0f…8a706`](https://monadscan.com/tx/0xf3696f0f2d461caf4bcb2d555551460b2016ed264730a055ea34c78a9b38a706) | routed **0.1 MON → 2 123 USDC micro-units** through the live WMON/USDC 0.3% pool [`0x659bD0BC…4a9da`](https://monadscan.com/address/0x659bD0BC4167BA25c62E05656F78043E7eD4a9da), above the signed floor of 2 118; zero WMON dust; status success |
| 3. Anchor the **yield** commitment | AuditAnchorV2 | [`0xb41ff034…4b06f`](https://monadscan.com/tx/0xb41ff03413265d4c9195364e9547fbfc9f5ebaafab02b2804471cb3a5f14b06f) | sequence 1; a second signed order committing to the exact Morpho market and a `maxAssets` ceiling |
| 4. `supply(USDC/WBTC market, 2 123)` | MorphoSupplyAdapter | [`0xbfd90ffd…19fd4f`](https://monadscan.com/tx/0xbfd90ffdefea2fa91f0cd2a1e3b7ae178a7ad67e24af882e8d1eb13eb619fd4f) | supplied the **exact 2 123 USDC from step 2** into the live **Morpho Blue USDC/WBTC market** (`0xe35c5abc…8899`); position **4 312 430 564 supply shares**, interest-accruing; zero dust in the adapter; status success |

A judge can read the three verified contracts, replay the events, and confirm
each execution matches its anchored commitment, without trusting us.

**Why the two legs carry separate orders.** The July 2026 write-up of the V1
deployment described "one `orderHash`" threading all three steps. That is no
longer true, and the change is the point. V1 gated on `lastHash[anchorer]` — a
single slot recording that an address had approved *something*, which any
execution by that address satisfied. V2 stores a commitment per
`(user, orderHash)` describing one exact execution, and both executors read
that same slot expecting to find *their own* commitment in it. Two different
executions therefore require two anchored orders. The yield leg's order commits
to a `maxAssets` **ceiling** rather than an exact amount, because it spends the
output of a swap whose result is not known at signing time; the adapter
enforces `assets <= maxAssets`.

**Honest scope.** There is still **no quantum advantage** at this
problem size (8 qubits — a classical solver is optimal and instant; the
value is the hybrid pipeline + real-hardware + error-mitigation demo,
not speedup). What is now proven on mainnet *with real value* is the
full settlement path: PQ-signed, anchored decision → real DEX swap
(MON → USDC) → real yield deposit (USDC lent into a live Morpho market,
now accruing ~4.75%). One protocol family is covered end-to-end (Morpho
lending); other pool types in the pitch (e.g. shMONAD staking) would
each need their own deposit adapter built to the same anchor-gated
pattern as `MorphoSupplyAdapter`. The claim is precise: the agent's
decision now settles as an anchored, on-chain, **yield-bearing**
position on Monad mainnet.

**Known limitation — the optimiser's universe is wider than the
executable one.** This is visible in the shipped artefacts, so we state it
rather than leave it to be found. `outputs/signed_orders.json` records
`pools: [Morpho STEAKETH, Neverland USDC, shMONAD]` at 33.3% each — the
QAOA selection — while its `execution` block routes **100% into USDC** and
supplies a single Morpho market. Both are covered by the same PQ
signature, so nothing is tampered with; but the quantum decision and the
on-chain action are not yet the *same* allocation.

The cause is structural, not a bug. The optimiser scores an 8-pool
universe drawn from DeFiLlama, three of which (Sky sUSDS, Ethena sUSDe,
Maple USDC) are on **Ethereum**, and the Monad ones are lending/staking
positions rather than Uniswap pairs. We have exactly two execution
adapters — Uniswap v3 and one Morpho market — and on Monad only the
WMON/USDC 0.3% pool has real depth (measured 2026-07-30: it returns a
flat ~20 770 micro-USDC per MON from 0.1 up to 1 000 MON, while the 0.05%
tier degrades ~89% over the same range). So the executable set today is
one liquid pair plus one lending market.

Closing this means either narrowing the optimiser to the reachable set —
the honest, small fix — or building per-protocol adapters for shMONAD,
Neverland and the Morpho vaults. Until then, read the `pools` field as
*the decision* and the `execution` block as *what was settled*, and treat
the link between them as reported rather than enforced.

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

### Real on-chain trade execution — `RoutingVault` + MiniAMM (testnet foundation)

> **Note:** this testnet mini-DEX was the *proof-of-mechanism* built when no
> DEX existed on Monad testnet. It has since been **superseded on mainnet** by
> `UniswapRoutingVault` (real Uniswap v3) + `MorphoSupplyAdapter` (real Morpho
> lending) — see "Now live on Monad mainnet" above. Kept here as the
> reproducible testnet lineage.

Six contracts deployed and Monadscan-verified on Monad testnet:

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
via `cast call` without trusting us. That successor is **now built and
executed**: `UniswapRoutingVault`, which calls the live Uniswap v3
router on Monad mainnet, ran the same loop with real value on
2026-07-12 (see "Now live on Monad mainnet" above). The agent-facing
`Routed` event shape is unchanged, so historical orders remain
replayable across the testnet→mainnet upgrade.

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

**Closing the on-chain gap without waiting for the chain — ZK ML-DSA
verification (`zk-mldsa/`).** Verifying ML-DSA-65 directly in the EVM
is estimated at ~500M gas — infeasible against any block limit. That figure is a published estimate we did not measure; what we DID measure is the replacement. Instead we move the lattice verification
off-chain into the **SP1 zkVM** and check a Groth16 proof on-chain for a
**measured 1 196 224 gas** (`attest()` tx `0x3ec51f36…d56de`)
on-chain. The guest verifies the **real mainnet order's** ML-DSA-65
signature (pure Rust `ml-dsa` crate — confirmed byte-compatible with the
pipeline's quantcrypt signatures) and commits **both** `SHA-256(order)`
and `SHA-256(public key)`. Committing the key fingerprint is not
cosmetic: with only the order hash, the proven statement was
existentially quantified over the signing key — *"some keypair signed
something hashing to X"* — so anyone could generate their own keypair,
sign an order of their own invention, and mint a valid attestation. The
contract pins the expected fingerprint as an immutable and rejects any
other signer. We accelerated ML-DSA's SHAKE by patching the `keccak`
permutation to SP1's keccak precompile (`vendor/keccak`), cutting the
trace to **2,036,531 cycles**. The committed `orderHash` is
`0xd8bf1551…15f9` — the same order anchored, swapped and Morpho-supplied
on mainnet on 2026-07-30. The STARK→SNARK **Groth16 wrap** (which OOMs
on a 15 GB dev box) was completed on a 64 GB cloud instance (~$0.32),
producing a 356-byte EVM-verifiable proof. **That proof was then verified
on-chain by SP1's own Groth16 verifier deployed on Monad mainnet, and
permanently recorded as PQ-attested** — the full on-chain post-quantum
settlement, executed:

| | Address / TX (Monadscan-verified) |
|---|---|
| MLDSAAttestation (mainnet) | [`0xb0aADaFe68647578520E988b4444e556c300b4Da`](https://monadscan.com/address/0xb0aadafe68647578520e988b4444e556c300b4da) |
| SP1 Groth16 verifier used | `0x7DA83eC4…2abd` (Succinct's canonical Monad deployment) |
| Program vkey (immutable) | `0x00ed29f3eb27b863b25c2619776ecc56c8c84e90b7da27250c8317cc2758cbd5` |
| Agent pkHash (immutable) | `0xac0b2aea57e0d9188717e9dada2042a60e2cae45bff90eccde9c1be13f5702ad` |
| `attest()` tx | [`0x3ec51f36…d56de`](https://monadscan.com/tx/0x3ec51f366d7d7944742f808cef8f897a750be881bddda6aa7a171880377d56de) — Groth16 proof verified on-chain (1 196 224 gas); `PQOrderAttested(0xd8bf1551…)` emitted; `pqAttested[orderHash] == true` |

**Reproducibility caveat, stated because it matters to anyone checking
this.** The program vkey is a hash of the compiled guest ELF, and the ELF
is not byte-reproducible across toolchains: the proving box built the
guest from source and produced vkey `0x00ed29f3…`, where the dev box's
build gives `0x00364772…`. Only the former verifies — SP1's on-chain
verifier accepts the proof under `0x00ed29f3…` and *reverts* under
`0x00364772…`, which we checked before deploying rather than assuming.
The deploy script therefore reads the vkey **out of the proof fixture**
rather than from an operator-supplied value; had the locally-computed
vkey been typed in, `verifier`, `mldsaProgramVKey` and `agentPkHash`
being immutable would have made the contract permanently unusable. A
third party rebuilding the guest will get a different vkey unless they
reproduce the toolchain; SP1's Docker guest build is the route to closing
that, and it is not yet wired in here.

So the agent's decision now carries an **on-chain, zero-knowledge proof
of its post-quantum ML-DSA-65 signature** on Monad mainnet, without the
estimated ~500M-gas cost of verifying ML-DSA natively in the EVM. Measured replacement: 1 196 224 gas, a ~420x reduction.

**Precisely what this does and does not do.** `pqAttested[orderHash]` is an
on-chain *record* that a valid ML-DSA-65 signature by the pinned key exists
over that order. It is **not** a *gate*: `grep -rn pqAttested contracts/src/`
returns nothing, and `AuditAnchorV2`, `UniswapRoutingVault` and
`MorphoSupplyAdapter` never read it. Settlement is authorised by
`execCommitmentOf[user][orderHash]`, which is written by an ordinary
secp256k1 ECDSA transaction. An attacker holding the deployer key could
anchor a commitment and execute a trade having broken no post-quantum
scheme; the PQ signature is enforced by `_verify_or_raise` inside the Python
builders, which such an attacker would simply not run.

So this closes the *cost* barrier to on-chain PQ verification — the part
that was previously infeasible — and demonstrates the primitive end to end.
It does not yet make PQ authorisation mandatory for settlement. Wiring the
executors to require `pqAttested[orderHash]` is the step that would, and it
is a contract change, not a research problem. Honest scope
unchanged: no quantum advantage anywhere; this is the PQ-*settlement*
path, proven end to end.

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

**279 tests, none skipped** (`pytest tests/ && forge test`), re-run
2026-07-31 against live Monad mainnet.

**110 Python tests**
- `test_pq_signing.py` (32) — SLH-DSA variant lock-in; round-trip and
  tamper detection for ML-DSA, SLH-DSA and Ed25519; strict
  canonicalisation (NFC validation, sorted keys, no NaN); strict `verify`
  typing; `ensure_keypair` refuses to silently generate a new identity.
- `test_monad_tx.py` (35) — calldata round trip against the PQ-signing
  layer; selectors verified against `forge inspect`; `MONAD_CHAIN_ID`
  locked at 143; fractional-weights → basis-points round-trip sums to
  10 000; commitment goldens pinned to `cast`; the twelve brickable
  route classes rejected by `validate_route_execution`.
- `test_quoter.py` (18) — live-quote calldata pinned byte-for-byte to
  `cast abi-encode`; every failure path refuses rather than falling back
  to a hardcoded rate; fee tiers outside {500, 3000, 10000} rejected.
- `test_orders_auditlog.py` (8) — writer and verifier normalise a log
  line identically under five terminator variants; reverse scan survives
  entries beyond the initial window; the shipped log still verifies.
- `test_pq_policy.py` (17) — the negative tests for the two policy flags
  that carry the M-1 and Z-2 defences: key pinning rejects a
  self-consistent forgery signed with the attacker's own three keypairs;
  one wrong pinned key out of three is enough to reject; stripping a
  signature leg fails under `require_hedged=True`; corrupting any single
  leg fails the whole order (the combiner is AND); a schema-v2 order with
  no execution block is rejected by default; and `canonical_bytes` refuses
  non-string dict keys (L-4).

**169 Foundry tests**, of which **70 are an adversarial red-team suite**
(`contracts/test/redteam/`, RT01–RT11) that reproduces each audit finding
and then asserts it closed — several against the real Uniswap v3 and
Morpho Blue deployments on a mainnet fork. Largest suites:
`UniswapRoutingVault` (21), `MonadAllocationVault` (13), `RoutingVault`
(12), `RT08_CommitmentDomainSeparation` (10), `RT06_V2BindingSurface` (9),
`RT09_DeployGuards` (8+1 fork), `RT03_DustInvariantAttacks` (8),
`AuditPoC_DustDoS` (8), `AuditAnchor` (8), `RT07_SentinelBypass` (7+1
fork), `RT11_AnchorStateMachine` (6), `CommitmentParity` (6).

**Mutation-tested, not just counted.** A test count says nothing about whether
a guard is actually covered. Every security guard in `contracts/src/` was
deleted one at a time from a scratch copy and the suite re-run; a guard counts
as covered only if its removal makes a test fail. An external review found
**nine** guards that could be deleted with the whole suite still green —
concentrated on `MorphoSupplyAdapter` and `AuditAnchorV2`, which had no direct
tests at all (`AuditAnchor.t.sol` imports the superseded V1). Seven are now
killed by `test/AuditAnchorV2.t.sol` and
`test/MorphoSupplyAdapterGuards.t.sol`, each asserting the exact revert
selector rather than a bare `vm.expectRevert()`.

The remaining two are the post-transfer `forceApprove(spender, 0)` calls, and
they are **provably unobservable rather than untested**: `transferFrom`
decrements the allowance by exactly what it moves, so a leftover allowance
implies the spender consumed less than was handed over — which the
balance-delta invariant in the same function already reverts on. The two
conditions cannot both hold. Both lines are annotated in the source with that
reasoning and kept as defence in depth.

One test was rewritten rather than added: the reentrancy case originally
passed because the nested call died on `AnchorNotFound` — the mock's own
address had no anchor — so `nonReentrant` was never reached. It now anchors
and funds the attacker so the nested call is valid in every respect except
its nestedness, and asserts the returndata is
`ReentrancyGuardReentrantCall()`. Deleting `nonReentrant` now fails it.

## Why this fits the challenge

- **Area 3 (primary) — Digital Infrastructure Secured Against Quantum
  Computing.** The PQ signing layer is not narrative — it is verified by
  **110 Python tests** (32 PQ-signing, 35 Monad-TX encoding, 18 live-quote,
  8 audit-chain) and **169 Foundry tests**, of which **70 are an adversarial
  red-team suite** (`contracts/test/redteam/`) that reproduces each
  vulnerability found in the July 2026 audit and then asserts it is closed —
  several against the real Uniswap and Morpho deployments on a mainnet fork.
  279 tests, none skipped. The artefacts are tamper-evident and a reviewer can
  audit them without running the code. **The full loop is LIVE on Monad
  mainnet (chainId 143), all contracts Monadscan-verified**:
  [AuditAnchorV2](https://monadscan.com/address/0x8422b555dce11913a4657c2f47c839637fc71ffd),
  [UniswapRoutingVault](https://monadscan.com/address/0x06f233062ee23590e5cc873df511024f3d981e56) (real Uniswap v3 swap),
  [MorphoSupplyAdapter](https://monadscan.com/address/0x8d5ae2f23e5d20bfb7915168d6b2a3ce753fe49e) (real Morpho lending deposit), and
  [MLDSAAttestation](https://monadscan.com/address/0xb0aadafe68647578520e988b4444e556c300b4da)
  (the order's ML-DSA-65 post-quantum signature **verified on-chain via a
  zero-knowledge proof**). One PQ-signed agent decision → SHA-256 anchored
  → real MON→USDC swap → real USDC supplied to a live lending market →
  on-chain ZK attestation of the PQ signature. The routing leg and the ZK
  attestation share `orderHash 0xd8bf1551…15f9`; the yield leg carries its
  own signed order, because AuditAnchorV2 binds one commitment per order
  and each executor demands its own. Aligned with the NIST FIPS 204
  algorithm NEAR Protocol committed to at L1 on 2026-05-06 — the first
  major L1 to commit to a NIST-finalised PQ signature option at the
  account layer.
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
capability extension. The mainnet deploy is **already done** (see the
"Now live on Monad mainnet" section above) — it was gas-trivial, exactly
as predicted; what the live system credibly needs next is the audit +
bounty + HSM steps below before it protects institutional value.

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

6. **Mainnet deployment — DONE.** AuditAnchor, UniswapRoutingVault,
   MorphoSupplyAdapter, and MLDSAAttestation are live and Monadscan-
   verified on Monad mainnet (chainId 143), and the full loop was
   executed with real value. Gas was trivial, as predicted. The audit
   (item 1) is the gate before this protects institutional value.

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
