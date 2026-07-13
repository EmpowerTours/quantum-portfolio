# Santander X Global Challenge — Quantum AI Leap · Stage 2 (Validation)

> Working draft to transcribe into the official form. `[FILL: …]` marks items
> only you can provide. Deadline: **2026-07-22 23:59 CET**. Contact:
> sx.challenge@oxentia.com. Honest framing preserved throughout — no
> quantum-advantage claims, no capabilities the code doesn't have.

---

## 0. Applicant & basics

- **Legal entity:** EmpowerTours SAS de CV
- **Country of incorporation:** Mexico (qualifies under the LATAM/Mexico startup criteria)
- **Incorporation date / RFC / registry no.:** `[FILL]`
- **HQ / registered address:** `[FILL: full Mexico address]`
- **Website:** `[FILL: e.g. empowertours.xyz]`
- **Socials:** GitHub `github.com/EmpowerTours` · X/Twitter `[FILL]` · LinkedIn `[FILL]` · Farcaster `[FILL]`
- **Primary contact:** `[FILL: name]`, empowertours@gmail.com
- **Logo:** `[ATTACH: assets/logo]`
- **Pitch deck link:** `[FILL: hosted PITCH_DECK.pdf URL]`
- **Repository (verifiable):** github.com/EmpowerTours/quantum-portfolio
- **Application area:** Area 3 (primary) — *Digital Infrastructure Secured Against Quantum Computing*; Area 2 (secondary) — *Quantum Software & AI-Driven Intelligence*

## 1. One-line pitch

Quantum-safe, verifiable settlement for on-chain finance — the post-quantum
provenance and signature-verification layer that works on today's chains,
proven end-to-end with real value on Monad mainnet.

## 2. The problem

Every public blockchain secures funds with ECDSA (secp256k1). A
cryptographically-relevant quantum computer breaks ECDSA via Shor's algorithm
("Q-Day"). Because chains are a permanent, public archive of signatures, this
is a **harvest-now, forge-later** threat: an adversary records signatures today
and forges them once quantum hardware arrives. The migration to NIST's
post-quantum signatures (ML-DSA/SLH-DSA, FIPS 204/205, finalised 2024) is
underway but blocked on-chain by two facts: PQ signatures are large (2–4 KB) and
verifying them natively in the EVM costs ~500M gas (infeasible), and base chains
cannot swap their native signature scheme quickly (many never will). So anything
that must stay verifiable for years needs post-quantum protection **now**, on the
chains that exist **today**.

## 3. The solution (three layers, each independently verifiable)

1. **Quantum + AI decisioning.** A hybrid QAOA (run on a real IBM Heron QPU,
   `ibm_marrakesh`) + AI-forecast pipeline produces a portfolio-allocation
   decision. Reported with statistical honesty — no advantage claimed at this
   scale.
2. **Hedged post-quantum signing.** Each decision is signed with **three**
   schemes at once — ML-DSA-65 + SLH-DSA-SHAKE-256s + Ed25519 — so the
   provenance survives a break in any single algorithm, and hash-chain-anchored
   into a tamper-evident audit log.
3. **On-chain, quantum-safe settlement.** The decision's hash is anchored
   on-chain, execution is *gated* on that anchor, and — the novel piece — the
   post-quantum signature itself is **verified on-chain via a zero-knowledge
   proof** for ~230k gas instead of ~500M, using an SP1 zkVM proof checked by a
   Groth16 verifier already deployed on the chain.

## 4. Validation — what is LIVE and verifiable (Stage-2 evidence)

**The entire loop runs on Monad mainnet with real value, all contracts
Monadscan-verified, all threaded by one provenance hash `orderHash 0xf9e798a1…`:**

| Component | Mainnet address (verified) | What it proves |
|---|---|---|
| AuditAnchor | `0x4cb79cc36b367a6fd7363bc6a8553a7a270da27c` | the PQ-signed decision existed & is immutable |
| UniswapRoutingVault | `0xe2fcada067227c817b8a47b850d727ba065e16dd` | real MON→USDC swap through live Uniswap v3 |
| MorphoSupplyAdapter | `0xB1a4341403DA395760561B85C4C96696C0D15958` | real USDC supplied into a live Morpho lending market (~4.75% APY) |
| MLDSAAttestation | `0xc1a82D8C4D28Eca8B318D1bac8DCc2Ab963b3839` | **the order's ML-DSA-65 post-quantum signature verified on-chain via a ZK proof; `pqAttested == true`** |

- A judge can click each contract, replay the events, and confirm the same
  32-byte `orderHash` threads the anchor → swap → yield → PQ attestation —
  **without trusting us.**
- Backed by **105 automated tests** (pipeline/PQ, Monad-TX ABI, Foundry
  contract tests) and a real IBM Heron QPU run with error mitigation.
- We produced the zero-knowledge proof of the real signature end-to-end
  (SP1 zkVM → Groth16), including a keccak-precompile optimization to make it
  tractable, for ~$0.32 of cloud compute.

This is the Stage-2 differentiator: **most "post-quantum DeFi" is a roadmap in a
deck. Ours is deployed, running, and independently verifiable.**

## 5. Market & use cases

The reusable technology — cheap on-chain verification of post-quantum
signatures + provenance-gated execution — applies wherever value is high and
integrity must outlast Q-Day:

- **Quantum-safe custody / smart-contract wallets** — high-value withdrawals
  require a PQ signature, ZK-verified on-chain.
- **Bridge & settlement attestations** — the highest-value, lowest-frequency
  on-chain actions and the #1 hack target.
- **Long-lived records / notarization** — titles, legal filings, IP timestamps,
  archival anchoring that must stay tamper-evident for decades.
- **Accountable AI agents** — as autonomous agents transact on-chain, a
  quantum-durable, cryptographic record of *which agent decided what* becomes a
  compliance/audit/insurance requirement. (This is exactly what we prototyped.)

Where a small, early team can win a wedge — and our natural next product — is
**quantum-safe provenance for autonomous on-chain AI agents**, at the
intersection of three funder-relevant narratives (AI agents + post-quantum + ZK).

## 6. Business model

- **B2B infrastructure / SDK.** The PQ-provenance + ZK-verification module,
  licensed or usage-priced, integrated by wallets, custodians, bridges, and
  agent frameworks.
- **Pilots with institutional treasuries** — quantum-safe crypto exposure on
  rails we can prove are honest (the Santander pilot thesis).
- Not consumer, not a token play at this stage — infrastructure sold to teams
  who hold value that must survive Q-Day.

## 7. Traction & milestones to date

- Full quantum→PQ→on-chain-settlement loop **deployed and verified on Monad
  mainnet with real value** (2026-07).
- Real IBM Heron QPU execution with documented error-mitigation results.
- Zero-knowledge on-chain verification of a real ML-DSA-65 signature — live.
- Accepted to **Santander X Stage 2 (Validation)**.
- Open, reproducible codebase; a reviewer can verify every claim on-chain.

## 8. Use of funds (12-month plan, highest-leverage first)

1. **Security audit** of the full stack (contracts + PQ canonicalisation +
   audit-chain + ABI encoders) by a reputable firm — **$50–200K**. The single
   biggest credibility uplift before any institutional pilot.
2. **HSM-backed agent custody** — move signing keys off the filesystem into
   AWS KMS / Cloud HSM before any public bounty.
3. **Paid bug bounty** (Immunefi / Code4rena) on the protocol surface.
4. **Multi-oracle data-integrity layer** (Pyth + Chainlink + direct pool reads)
   — ~2 engineer-months; turns Area-3 compliance from defensible to
   institutional-grade.
5. **Productize the agent-accountability module + SDK** — the fundable wedge.
6. **Statistical power on the QPU runs** — ≥10 independent runs for a proper
   paired hypothesis test (IBM compute time is the cost driver).
7. **Institutional pilot** (treasury quantum-safe exposure) — the Santander
   thesis, made concrete.

## 9. Team

- `[FILL: founder name, role, background — quantum/crypto/eng credentials]`
- `[FILL: any co-founders / advisors / collaborators]`
- Currently a `[FILL: solo founder / small team]`; funding converts the
  deployed prototype into audited, pilot-ready infrastructure.

## 10. Eligibility & attachments (checklist)

- [ ] Certificate of incorporation (EmpowerTours SAS de CV, Mexico) — `[ATTACH]`
- [ ] Eligibility evidence (LATAM/Mexico startup criteria) — `[ATTACH]`
- [ ] Logo (high-res) — `[ATTACH]`
- [ ] Pitch deck (PDF, hosted link) — `docs/PITCH_DECK.pdf` → `[HOST + link]`
- [ ] HQ address, socials, founder details — filled in §0 / §9
- [ ] Repository link (already public) — github.com/EmpowerTours/quantum-portfolio

## 11. Honest framing (kept explicit — this is what makes the rest credible)

- **No quantum advantage** at this scale (8 qubits). The value is the working
  hybrid pipeline on real hardware, the error-mitigation demo, and — primarily —
  the deployed quantum-*safe* settlement infrastructure. This is **defense
  against** quantum, not use *of* quantum for speedup.
- The price-return backtest (Sharpe 1.59) **loses to a 1/N baseline (2.11)** at
  MVP scale — reported, not hidden.
- The on-chain settlement TX is still ECDSA-signed; the ZK layer proves the
  *decision's* PQ signature, and closing the settlement-TX gap fully is on the
  roadmap (documented in SECURITY.md as risk we are *preparing for*).
- The ML-DSA verification code is not yet independently audited (item #1 above).
