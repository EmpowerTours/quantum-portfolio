# Panel Q&A — scripted answers to predicted Santander reviewer attacks

Private prep document. Not part of the submission narrative. Read this once before any pitch session so the answers come out fast and confident, not improvised.

**House rules for this doc:**
1. Concede what's true first, then pivot. Reviewers respect honesty + a clean redirect more than a defensive wall.
2. Keep the 30-second answer to 30 seconds. The 2-minute answer is for when they press.
3. If you don't know something, say "let me get back to you on the exact number" — that's stronger than improvising a wrong figure.
4. Map every answer to a specific line in `SUBMISSION.md` or `SECURITY.md` so a follow-up "where is this documented?" lands instantly.

---

## The 30-second elevator pitch (always start here)

> "We ship a Q-Day-resistant audit-provenance layer for autonomous DeFi agents. The agent's portfolio decision runs on a real IBM Heron QPU with error mitigation, the decision is triple-signed off-chain with NIST FIPS 204 and FIPS 205 post-quantum signatures plus Ed25519, the SHA-256 is anchored on Monad via a deployed Monadscan-verified contract, and a companion vault records per-orderHash native MON deposits for custody-with-attribution. All of it is reviewer-reproducible — clone the repo, run `forge test`, run `cast call`, the numbers match. Primary target is Area 3, secondary is Area 2."

That's the frame. Every attack defence reroutes back here.

---

## Group 1 — Quantum value attacks

### Attack #1 — "8-qubit QAOA is solved exactly by classical in microseconds. You shipped a press release with a job ID."

**30-second answer:**
> "Correct, and we say so directly in SUBMISSION.md line 78 and on the app's hardware tab. The deliverable here isn't quantum advantage at n=8 — it's the *pipeline* + the *directional consistency check* on the mitigation lift. The pitch is Area 3 primary; the QPU run is verifiable hardware execution, not a performance result."

**If they press:**
> "Three points. One: the pipeline composes — when problem size reaches the regime where QPU is competitive (50+ qubits, deeper circuits), our exact same QAOA + mitigation stack scales without code changes. Two: the same direction has a peer-reviewed precedent — arXiv 2602.09047 ran portfolio QAOA + ZNE on Heron at 88 qubits and reported a statistically significant 31.6% lift. We *cite* that as methodological precedent only — we explicitly do not claim their p-value transfers to our 8-qubit single-run data. Three: Area 2 is positioned as 'ready to scale,' not 'shipping advantage today,' which is the only honest framing we can give and pass an IBM-co-sponsored review with."

**Pivot:** "The shipped value is Area 3. Want me to walk through the on-chain provenance trail?"

**Pre-empted follow-up: "Why didn't you do 50 qubits then?"**
> "IBM Quantum compute time. The 4096-shot single run on n=8 is what fit in our free credits. Funded item #5 in the funding section is exactly this — more shots, more runs, until α=0.05 significance is reachable or the lift turns out to be noise."

---

### Attack #11 (NEW from second-pass review) — "Your +67% lift is statistically untested. Wilson CIs overlap. Fisher exact p~0.16. You printed a ratio of two small frequencies and called it a result."

**This is the most technically substantive attack we'll face.** Memorise the numbers.

**30-second answer:**
> "You're right that the single-run lift is underpowered. SUBMISSION.md table on line 54 now reports the raw counts (12 of 4096 raw, 20 of 4096 mitigated), the Wilson 95% CIs (which overlap heavily: [0.16%, 0.53%] vs [0.30%, 0.77%]), and the Fisher exact p-value of approximately 0.16. We frame it as a *directional consistency check*, not a significance-tested lift. The arXiv 2602.09047 citation is methodological precedent — not a transitive significance claim."

**If they press on "why ship an underpowered number then":**
> "Two reasons. One: it's what the available QPU credits gave us, and we'd rather report it honestly than not at all — burying the number would be worse than caveating it. Two: directional consistency is still information. The mitigated > raw ordering holds across both runs (DeFi and stocks), which is what we'd expect under a real effect even at low power."

**Pivot:** "If we win, item #5 is the obvious spend: 10× shots on 10 independent runs, paired hypothesis test, settle the question."

**DO NOT SAY:** "+67% mitigation lift" without the caveats. Always say "directional consistency check" or "single-run lift, CIs overlap".

---

### Attack #12 (NEW) — "You cite arXiv 2602.09047's p=0.0009 to launder your own statistically-not-significant number."

**30-second answer:**
> "The citation is explicit about not transferring their significance — SUBMISSION.md says 'their stack (ZNE), scale (88 qubits), and replication (n=7) differ from ours (XY4+twirling, 8 qubits, n=1), so their p-value does not transfer.' We cite them as methodological precedent that mitigation can produce significant lifts on Heron portfolio QUBOs when properly powered — same direction, scaled down."

**If they press:**
> "You're welcome to read both papers side by side. Theirs is the headline result with statistical power; ours is a single-run consistency check that demonstrates the same pipeline composes. We don't pretend they're the same experiment."

---

### Attack #13 (NEW) — "Area 2 is hollow. No quantum advantage, AI loses to 1/N. What is Santander buying?"

**30-second answer:**
> "Area 3 is primary, Area 2 is secondary. SUBMISSION.md line 14 says exactly that. The Area 2 deliverable is the *infrastructure* — a hybrid QAOA + Ridge pipeline that runs verifiably on real hardware today and scales by parameter change when hardware and data catch up. The Area 3 deliverable is shippable value now: hedged PQ-signed orders, on-chain custody anchoring, end-to-end reviewer-reproducible. Funding pays for the Area 2 component to mature — more shots, larger backtest, better forecaster — while Area 3 goes to mainnet."

**If they press:**
> "The honest read is: Area 2 alone wouldn't justify the submission. Area 3 alone might. The combination demonstrates that we know how to build production crypto infrastructure for AI-driven trading agents — and that's what Santander finance is going to need when both quantum hardware and Q-Day arrive."

---

## Group 2 — On-chain / vault attacks

### Attack #4 — "Your vault doesn't execute. It records a deposit and emits an event. Calling it 'allocation vault' is a category error."

**30-second answer:**
> "Correct. The vault is *custody + audit event*, not trade execution — SUBMISSION.md section header is literally 'On-chain custody anchor', and the 'What this is and is not' paragraph says explicitly it does not swap, route to a DEX, or generate yield. The reason: we hunted six sources for a working DEX on Monad testnet — GeckoTerminal, MonadVision, MCP-MONI, mainnet-V3 deterministic addresses, Uniswap deployer's actual CREATE2 outputs, and *Kuru's own official docs* — all returned empty bytecode. The testnet has no working DEX today. We ship the *agent-facing protocol* now, with a stable Allocated event shape that survives a future routing-aware upgrade."

**If they press on "so it's a placeholder":**
> "It's the smallest contract that gives the agent's decision an on-chain effect with reversible custody — the user can withdraw at any time. That's a real primitive. When a DEX ships on Monad testnet, we upgrade by deploying a routing-aware successor; the event shape stays stable so historical orders remain replayable against the on-chain log."

**Pivot:** "What we ship is a *reference implementation* for the agent → vault interface. Production deployments target real protocols — Morpho, Upshift, shMONAD — when their testnet contracts go live."

---

### Attack #5 — "On-chain TX is ECDSA. Shor breaks ECDSA. Your 'quantum-safe' name contradicts your threat model."

**30-second answer:**
> "Documented honestly in SUBMISSION.md 'Q-Day caveat on the on-chain leg' (line 263) and SECURITY.md threat-model row 'Q-Day quantum attacker (on-chain): NO — outside MVP scope'. The off-chain triple-signed audit trail survives Q-Day; the on-chain anchor and vault deposit TXs inherit Monad's ECDSA Q-Day exposure. When Monad ships a chain-level PQ TX scheme — and NEAR has already committed to ML-DSA for Q2 2026 — the anchor TX inherits that protection without code changes to our agent."

**If they press:**
> "The hybrid posture is the standard answer: cryptography you can ship today is hybrid PQ + classical; cryptography that's purely PQ requires chain-level support that doesn't exist on any major L1 yet. We're aligned with the same FIPS 204 algorithm NEAR Protocol committed to at L1 on 2026-05-06."

---

### Attack #6 — "PQ signature proves WHO signed, not WHO is allowed to allocate. On Q-Day, an attacker who steals the agent's ML-DSA key signs anything."

**Most technically substantive attack on the list. There is no clean fix today.**

**30-second answer (do not improvise this one):**
> "Correct, and we'd rather you raise it now than after we deploy. The current PQ layer is signature, not capability. Closing the gap requires a capability registry contract on Monad — issuer → agent → max allocation per pool, time-bounded — which is funded item #7 in the funding section. We did not ship it because building it well requires the security audit and stakeholder definition that the prize funds. The current scope is 'authenticated agent intent + reversible custody'; capability authorisation is the next protocol layer."

**If they press on "so anyone with the key wins":**
> "Yes — and the same is true for every ECDSA wallet in production today. The funded HSM line item #4 closes the key-extraction attack. The funded capability registry #7 closes the unauthorized-allocation attack. Both are concrete protocol work, not handwaves."

**Pivot:** "Want me to walk through what the capability registry would look like architecturally?"

---

### Attack #9 — "Your vault has 0.02 MON in it and one user. This isn't a deployment, it's a screenshot."

**30-second answer:**
> "It's a demo. SUBMISSION.md 'On-chain footprint disclosure' (line 308) says exactly that: one deployer wallet, four anchors, two vault deposits totalling 0.02 MON. The pitch is *provable composability* of the three-layer chain — off-chain PQ-signed order, on-chain anchor, on-chain custody — not on-chain TPS. The TXs are real and Monadscan-verified; the trail is byte-linked through the same orderHash; a reviewer with the repo URL can verify all of it in three `cast call` commands."

**If they press on "so it's not a real deployment":**
> "Mainnet deployment is funded item #6 and explicitly gated behind the security audit (items #1-#3). We're not asking €120K to pay for $50 of mainnet MON; we're asking it to pay for Trail of Bits or OpenZeppelin to sign off on the source first."

---

## Group 3 — Crypto / data integrity

### Attack #7 — "DeFiLlama is unauthenticated public REST. Your optimiser eats whatever any HTTP server in the request chain returns."

**30-second answer:**
> "Acknowledged in SECURITY.md 'Off-chain data sources are trusted-but-not-verified' (line 126). A successful man-in-the-middle or upstream data poisoning would feed manipulated yields into the QUBO. Production deployment requires either multi-source consensus or an on-chain oracle with cryptographic proofs — that's funded item #3, with explicit Pyth + Chainlink + direct pool-read implementations called out."

**If they press:**
> "This is a known property of any DeFi protocol consuming off-chain price data. Our submission is honest that it's an MVP-scope item, not a solved problem. The right comparison is to other competitive entries — most of which probably trust a single yield feed without saying so."

---

## Group 4 — AI / backtest

### Attack #8 — "Your AI loses to equal-weight 1.59 vs 2.11. Santander is funding a pipeline whose AI makes the portfolio worse than no AI."

**30-second answer:**
> "Reported, not hidden — SUBMISSION.md line 432 says the AI underperforms 1/N at this scale. This is the result of a lookahead-free walk-forward; pre-fix the lookahead leak made the AI look better than it is, and we closed that gap in commit `e4ead4a`. We ship the integrity result, not an inflated alpha number."

**If they press on "so what is the AI for":**
> "Two answers. One: the AI layer is plug-and-play. Ridge regression is a transparent baseline that exposes when it fails — funded item #9 swaps it for a learned model. Two: at the rebalance frequency we ship (monthly) on 8 pools with a 1-year window, no model would beat equal-weight reliably. The pipeline value is the *infrastructure* that lets you swap forecasters; the AI baseline is the floor, not the ceiling."

---

### Attack #2 — "Your signed-order Sharpe is 52, your backtest Sharpe is 1.59. Either one of these is broken."

**30-second answer:**
> "The single-order's `expected_vol` field is yield-volatility — the annualised standard deviation of daily APY drift on stablecoin / staking pools, ≈0.34%. That implies Sharpe ≈52, which is yield-Sharpe in a Treasuries-like regime, not a price-return alpha claim. The backtest's 1.59 is the price-return Sharpe on the same selection, which is the alpha-comparable number. SUBMISSION.md line 431 spells this out explicitly."

**If they press:**
> "Yields on Aave, Morpho, Curve LP positions move slowly — sub-1% APY day-to-day variance is normal. The token *price* of WBTC or WETH moves at ±50% annualised vol; the *yield* on a USDC lending position moves at ±0.5%. We measure the latter because that's the agent's actual risk surface when capturing yield."

**DO NOT SAY** the word "Sharpe 52" without the qualifier "yield-Sharpe" attached. The combined phrase is fine; standalone is the attack surface.

---

## Group 5 — Strategy / business

### Attack #14 (NEW) — "Mainnet deploy is deferred behind the prize. That's $50 of MON; you're padding the funding ask."

**30-second answer:**
> "Mainnet deploy is funded item #6, not item #1. Items 1-3 are paid audit ($50-200K), bug bounty ($25-100K+), and multi-oracle integration. The mainnet deploy is the routine final step *after* the audit signs off. We didn't deploy on mainnet on day one because deploying unaudited PQ-signing infrastructure to a chain holding real money would be irresponsible."

---

### Attack #3 — "You call this an 'agent' but the Python code is the agent. Where is the agency?"

**30-second answer:**
> "Agency here means 'autonomous signing entity with its own keypair and audit log,' not 'LLM-driven decisioning.' The PQ keys identify the agent cryptographically; the audit log preserves its decision history; the on-chain anchor commits the decisions to Monad. That's the agency layer Santander cares about for a production trading bot — *who* is allowed to allocate capital, with *cryptographic* attribution, *Q-Day-resistant*."

**If they press on "but a script could do that":**
> "Yes — and that's the point. The cryptographic identity layer is decoupled from the decision-making layer, so the decision engine can be a Ridge regressor today, a transformer tomorrow, a quantum-classical hybrid the year after. The audit infrastructure outlives the model. That's the value."

---

## Templates for when you don't know

If a panelist asks something specific you can't answer immediately:

> "Let me check the exact number — I'd rather give you the right one than guess. I'll send a follow-up after the session."

For implementation details:
> "That's a question for the implementation; let me pull up the repo." *(Open SUBMISSION.md or the source on your laptop.)*

For competitive positioning:
> "We focused on building the honest version. I don't have a competitive analysis I'd defend in front of a panel."

For something that's actually broken:
> "You've found something. Let me make sure I understand it correctly before answering" — then think for 5 seconds before responding. Don't fight an attack that just landed.

---

## Pre-empted "what about X" answers

**"What about FN-DSA / Falcon?"**
> Funded item #8. NIST hasn't finalised it as of mid-2026; projected late-2026 / early-2027. When the spec freezes, we add it as a fourth hedge with the smallest signature size for the on-chain calldata path. Until then, hedging on three independent assumptions (lattice / hash-based / classical) is the standard hybrid posture.

**"What about NEAR Protocol's ML-DSA shipment?"**
> NEAR Protocol committed to FIPS 204 ML-DSA at L1 on 2026-05-06, with Q2 testnet rollout planned. Source: BanklessTimes 2026-05-07, linked from SUBMISSION.md. We sign with the same algorithm. We're explicit they haven't shipped to mainnet yet — neither have we — but it's the strongest signal that the standardised stack is on a production trajectory.

**"What about Kuru / Uniswap on Monad?"**
> No working DEX on the current Monad testnet — we verified by reading Kuru's official docs and querying every cited router/token address against the live RPC. The testnet appears to have been reset around 2025-12-16 and ecosystem documentation hasn't caught up. Permit2 and the ERC-4337 EntryPoint are the only Uniswap-deployer contracts confirmed live. That's why we ship a custody-vault now and defer DEX routing.

**"Why MIT license?"**
> We want this protocol to be replicable. MIT is compatible with every runtime dependency we use (quantcrypt, cryptography, qiskit, streamlit — all Apache 2.0 or BSD), and a permissive license is the right choice for infrastructure we want production teams to adopt.

**"What's your moat?"**
> Honest answer: the moat is execution — we shipped this end-to-end with verified contracts and a real provenance trail before most competitors had a working testnet TX. If we win, the audit + bounty + multi-oracle work is what makes the moat defensible.

**"Why Mexico?"**
> EmpowerTours SAS de CV is incorporated in Mexico, which qualifies under the Santander X LATAM startup criteria. Our engineering is distributed.

---

## Final reminder before the session

- Print this doc. Mark the three attacks you fear most.
- Open SUBMISSION.md, SECURITY.md, and Monadscan in browser tabs.
- Have `cast` ready in a terminal in case a reviewer wants you to run a verification live.
- The 30-second answers go first, always. The 2-minute versions are only for when they actually press.
- If you don't know something, say so. Improvising wrong numbers is the only attack we cannot recover from in real time.
