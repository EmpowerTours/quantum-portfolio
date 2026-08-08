---
marp: true
theme: default
paginate: true
size: 16:9
style: |
  :root {
    --bg: #0b1020;
    --ink: #f5f7ff;
    --accent: #6cf0ff;
    --accent2: #ff6cd6;
    --muted: #8b95b8;
    --mono: ui-monospace, SFMono-Regular, "JetBrains Mono", Menlo, monospace;
  }
  section {
    background: var(--bg);
    color: var(--ink);
    font-family: Inter, system-ui, -apple-system, "Segoe UI", sans-serif;
    font-size: 28px;
    padding: 72px 96px;
  }
  section.title {
    background:
      radial-gradient(1200px 600px at 80% -10%, rgba(108,240,255,.18), transparent 60%),
      radial-gradient(900px 500px at 0% 110%, rgba(255,108,214,.14), transparent 60%),
      var(--bg);
  }
  h1 { color: var(--ink); font-weight: 800; letter-spacing: -0.02em; font-size: 64px; line-height: 1.05; }
  h2 { color: var(--ink); font-weight: 700; font-size: 44px; letter-spacing: -0.015em; }
  h3 { color: var(--accent); font-weight: 600; font-size: 22px; letter-spacing: 0.18em; text-transform: uppercase; margin-bottom: 8px; }
  strong { color: var(--accent); }
  em { color: var(--accent2); font-style: normal; }
  code { font-family: var(--mono); color: #dcefff; background: rgba(255,255,255,.10) !important; padding: 2px 8px; border-radius: 6px; }
  pre { background: #0d1526 !important; border: 1px solid rgba(255,255,255,.12); border-radius: 12px; padding: 6px; }
  pre code { background: transparent !important; color: #e9edff; display: block; padding: 18px 24px; border-left: 3px solid var(--accent); border-radius: 0; font-size: 21px; line-height: 1.75; }
  blockquote { border-left: 3px solid var(--accent2); color: var(--muted); padding-left: 20px; font-style: italic; }
  hr { border: none; border-top: 1px solid rgba(255,255,255,.08); margin: 24px 0; }
  ul { line-height: 1.55; }
  li::marker { color: var(--accent); }
  table { width: 100%; border-collapse: collapse; font-size: 22px; background: transparent !important; border: none; }
  thead, tbody, tr { background: transparent !important; border: none; }
  th, td { border: none; border-bottom: 1px solid rgba(255,255,255,.10); padding: 12px 14px; text-align: left; background: transparent !important; color: var(--ink); }
  th { color: var(--accent); font-weight: 600; letter-spacing: 0.05em; text-transform: uppercase; font-size: 18px; }
  a { color: #7fe3ff; text-decoration: underline; text-underline-offset: 3px; }
  .addrs { background: #0d1526; border: 1px solid rgba(255,255,255,.12); border-radius: 12px; font-family: var(--mono); font-size: 19px; margin-top: 8px; }
  .addrs td { border-bottom: 1px solid rgba(255,255,255,.07); padding: 12px 22px; }
  .addrs tr:last-child td { border-bottom: none; }
  .addrs .cn { color: var(--muted); }
  .addrs a { color: #7fe3ff; }
  footer, header { color: var(--muted); }
  section::after { color: var(--muted); }
  section.dense { font-size: 23px; padding: 48px 72px; }
  section.dense h1 { font-size: 46px; line-height: 1.06; }
  section.dense h2 { font-size: 30px; }
  section.dense h3 { font-size: 19px; margin-bottom: 4px; }
  section.dense table { font-size: 18px; }
  section.dense th, section.dense td { padding: 7px 10px; }
  section.dense ul { line-height: 1.35; }
  section.dense pre code { font-size: 17px; line-height: 1.5; padding: 12px 16px; }
  section.dense blockquote { padding-left: 14px; }
  section.dense p { margin: 0.5em 0; }
  section.xdense { font-size: 20px; padding: 40px 64px; }
  section.xdense h1 { font-size: 38px; line-height: 1.05; }
  section.xdense h2 { font-size: 25px; }
  section.xdense h3 { font-size: 17px; margin-bottom: 3px; }
  section.xdense table { font-size: 16px; }
  section.xdense th, section.xdense td { padding: 5px 8px; }
  section.xdense ul { line-height: 1.3; }
  section.xdense pre code { font-size: 15px; line-height: 1.45; padding: 10px 14px; }
  section.xdense p { margin: 0.4em 0; }
  .kicker { color: var(--accent); letter-spacing: 0.18em; text-transform: uppercase; font-size: 18px; font-weight: 600; margin-bottom: 16px; }
  .big { font-size: 88px; font-weight: 800; letter-spacing: -0.03em; line-height: 1; color: var(--ink); }
  .big small { font-size: 22px; letter-spacing: 0.08em; color: var(--muted); text-transform: uppercase; display: block; margin-top: 14px; font-weight: 500; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 56px; align-items: start; }
  .grid-3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 40px; }
  .card { background: rgba(255,255,255,.04); border: 1px solid rgba(255,255,255,.06); padding: 24px 28px; border-radius: 14px; }
  .card h3 { margin-top: 0; }
  .pill { display: inline-block; padding: 4px 14px; border-radius: 999px; background: rgba(108,240,255,.12); color: var(--accent); font-size: 18px; letter-spacing: 0.08em; text-transform: uppercase; font-weight: 600; }
---

<!-- _class: title -->

<div class="pill">Santander X · Quantum AI Leap · 2026</div>

# EmpowerTours<br>Quantum Portfolio

## Q-Day-resistant DeFi, shipped today.

<br>

QAOA on IBM Heron · Hedged post-quantum signatures · On-chain provenance on Monad

---

<h3>The Threat</h3>

# Every ECDSA signature you<br>publish today is *a hostage*<br>to tomorrow's QPU.

<br>

> This is *not* harvest-now-decrypt-later — signatures aren't secret, and your orders are already public. It is worse in one specific way: the day the curve falls, every signature ever made with it becomes **forgeable**, so a genuine 2026 authorisation and one fabricated in 2035 are no longer distinguishable. Your audit trail stops proving anything. And on an EVM chain every transaction you have ever sent already exposes the public key that a QPU turns into your private key.

---

<h3>Why DeFi gets hit first</h3>

# Public chains are an<br>open archive of signatures.

<div class="grid">

<div>

- Every transaction broadcasts an **ECDSA signature** in the clear.
- Indexers store them *forever*.
- A cryptographically-relevant QPU forges any one of them.
- The chain doesn't know which.

</div>

<div class="card">

<h3>Today's defense</h3>

**None.** Most wallets still sign with secp256k1.<br>Most "post-quantum DeFi" decks are *roadmaps*.

</div>

</div>

---

<!-- _class: dense -->

<h3>The Stack</h3>

# Three layers. Each one<br>survives the other two.

<div class="grid-3">

<div class="card">
<h3>1. Allocate</h3>
<strong>QAOA</strong> on IBM Heron QPU picks Markowitz-optimal weights under risk constraints.
</div>

<div class="card">
<h3>2. Sign</h3>
<strong>Hedged PQ</strong>: every order carries ML-DSA-65 + SLH-DSA-SHAKE-256s + Ed25519. <em>Any one</em> survives.
</div>

<div class="card">
<h3>3. Anchor</h3>
<strong>SHA-256(order)</strong> committed to Monad's <code>AuditAnchorV2</code> before the vault will execute it.
</div>

</div>

<br>

> One layer broken ≠ system broken. The threat model is *every algorithm we trust today is provisionally trusted*.

---

<!-- _class: xdense -->

<h3>The Quantum Layer</h3>

# QAOA on real hardware,<br>reported with statistical honesty.

<div class="grid">

<div>

- **IBM Heron**, XY-ring-mixer QAOA, reps=3. Raw counts shipped — recompute it yourself.
- **Stocks universe** (`ibm_fez`): mitigation rescues the signal, **13 → 39** hits — **×2.19** vs random, raw **×0.76** (below chance). Fisher **p = 0.00039**, **n = 1** per arm.
- **DeFi universe** (`ibm_marrakesh`) — the one this product actually optimises: **22 → 22**, **p = 1.000**. *No mitigation effect at all.*

</div>

<div class="card">

<h3>What this is, honestly</h3>

QAOA is **not** faster than the classical baseline at this size — that baseline is `NumPyMinimumEigensolver` (brute-force exact, `src/solvers.py:33`), which is optimal and instant on 8 assets.

**And our strongest quantum result is not on our own universe.** We report the discrepancy rather than lead with the number that flatters us.

</div>

</div>

---

<!-- _class: dense -->

<h3>The Signature Layer</h3>

# Don't bet on one algorithm.<br>Hedge the bet.

<table>

<tr><th>Algorithm</th><th>Family</th><th>Why include</th></tr>
<tr><td><code>ML-DSA-65</code></td><td>Lattice (FIPS 204)</td><td>NIST PQ standard. Fast.</td></tr>
<tr><td><code>SLH-DSA-SHAKE-256s</code></td><td>Hash (FIPS 205)</td><td>Different math. Slow but conservative.</td></tr>
<tr><td><code>Ed25519</code></td><td>Classical EC</td><td>Battle-tested. Hedge for "did we mis-port a new standard?"</td></tr>

</table>

<br>

> If ML-DSA falls to a 2028 cryptanalysis paper, SLH-DSA still authenticates the order. If both lattice and hash fall, the classical signature carries it pre-Q-Day.

---

<!-- _class: xdense -->

<h3>The Provenance Layer</h3>

# A hash chain the vault<br>refuses to disobey.

<div class="grid">

<div>

1. Agent builds order. PQ-signs it.
2. <code>AuditAnchorV2.anchor(orderHash, execCommitment, seq)</code> on Monad mainnet. Commits the order <em>and the one execution it authorises</em>.
3. <code>UniswapRoutingVault.executeAndRoute(orderHash, …)</code> recomputes the commitment from its own calldata and reverts unless it equals <code>ANCHOR.execCommitmentOf[msg.sender][orderHash]</code>. Anchoring an order is not enough — the trade must be <em>the</em> trade that was signed for.

</div>

<div class="card">

<h3>What this kills</h3>

- Replay (sequence enforced per wallet)
- Off-chain order tampering (hash doesn't match)
- Vault impersonation (pair allowlist immutable per deploy)
- Sandwich-DoS (<code>amountOutMin</code> from caller, not on-chain quote)

</div>

</div>

---

<!-- _class: xdense -->

<h3>The obvious objection</h3>

# Yes — the chain transaction<br>is still signed with *ECDSA*.

<div class="grid">

<div>

**What we do NOT protect**

A quantum computer that breaks ECDSA does not need to forge our order. It takes the wallet key and moves the funds directly.

We do not claim otherwise. `SECURITY.md` states this before anyone asks — it is the first item under *What the code does not protect*.

</div>

<div>

**What we DO protect — today, no quantum computer required**

- **The instruction.** The vault recomputes the commitment from its own calldata and reverts unless the trade *is* the trade that was signed for. Anchoring is not enough.
- **The audit trail past Q-Day.** Signatures over the order stay unforgeable even after ECDSA falls.
- **The upgrade path.** When chains add post-quantum transaction signatures, the layer above them already exists.

</div>

</div>

<br>

> We protect the *instruction*, not the *key*. Key custody is the custodian's job — which is exactly why HSM custody gates our own managed-signing revenue rather than launching with it.

---

<!-- _class: dense -->

<h3>Proof, not promises</h3>

# Live on Monad MAINNET.<br>279 tests. ZK-verified.

<div class="grid-3">

<div>
<div class="big">4<small>contracts live<br>Monadscan-verified</small></div>
</div>

<div>
<div class="big">279<small>tests passing<br>110 Python + 169 Foundry</small></div>
</div>

<div>
<div class="big">3<small>signature algorithms<br>per order, hedged</small></div>
</div>

</div>

<br>

<table class="addrs">
<tr><td class="cn">AuditAnchorV2</td><td><a href="https://monadscan.com/address/0x8422b555dce11913a4657c2f47c839637fc71ffd">0x8422b555dce11913a4657c2f47c839637fc71ffd</a></td></tr>
<tr><td class="cn">UniswapRoutingVault</td><td><a href="https://monadscan.com/address/0x06f233062ee23590e5cc873df511024f3d981e56">0x06f233062ee23590e5cc873df511024f3d981e56</a></td></tr>
<tr><td class="cn">MorphoSupplyAdapter</td><td><a href="https://monadscan.com/address/0x8d5ae2f23e5d20bfb7915168d6b2a3ce753fe49e">0x8d5ae2f23e5d20bfb7915168d6b2a3ce753fe49e</a></td></tr>
<tr><td class="cn">MLDSAAttestation</td><td><a href="https://monadscan.com/address/0xb0aadafe68647578520e988b4444e556c300b4da">0xb0aadafe68647578520e988b4444e556c300b4da</a></td></tr>
</table>

---

<!-- _class: xdense -->

<h3>The end-to-end demo — real value, one hash</h3>

# QPU decision → PQ signature<br>ZK-verified on-chain → yield.

<table>

<tr><th>Step</th><th>Contract</th><th>What happened (Monad mainnet)</th></tr>
<tr><td>1. Attest</td><td><a href="https://monadscan.com/address/0xb0aadafe68647578520e988b4444e556c300b4da"><code>MLDSAAttestation</code></a></td><td>Order's <strong>ML-DSA-65 signature verified on-chain via ZK proof</strong> (1.20M gas measured, vs ~500M estimated for native EVM ML-DSA); <code>pqAttested = true</code></td></tr>
<tr><td>2. Anchor</td><td><a href="https://monadscan.com/address/0x8422b555dce11913a4657c2f47c839637fc71ffd"><code>AuditAnchorV2</code></a></td><td>Hash <code>0xd8bf1551…15f9</code> committed, immutable</td></tr>
<tr><td>3. Swap</td><td><a href="https://monadscan.com/address/0x06f233062ee23590e5cc873df511024f3d981e56"><code>UniswapRoutingVault</code></a></td><td>0.1 MON → <strong>2,123 micro-USDC</strong> (0.002123 USDC ≈ $0.002 — a deliberately tiny live-value demo) via live Uniswap v3, anchor-gated</td></tr>
<tr><td>4. Yield</td><td><a href="https://monadscan.com/address/0x8d5ae2f23e5d20bfb7915168d6b2a3ce753fe49e"><code>MorphoSupplyAdapter</code></a></td><td>USDC supplied into a live <strong>Morpho</strong> market (~4.75% APY), non-custodial</td></tr>

</table>

<br>

> The routing leg and the ZK attestation share one 32-byte <code>orderHash</code>; the yield leg carries its own signed order, because AuditAnchorV2 binds one commitment per order and each executor demands its own. A reviewer replays the events and verifies every step on-chain — without trusting us.

---

<h3>Why us</h3>

# We ship the part everyone<br>else handwaves.

<div class="grid">

<div>

- **Most PQ-DeFi pitches:** slides about a future migration.
- **Most QAOA-finance pitches:** one hand-picked seed on a simulator.
- **Most provenance pitches:** off-chain Merkle trees nobody verifies.

</div>

<div>

- **Ours:** verified contracts, real QPU runs with statistical rigor, on-chain hash chain enforced by the vault itself.
- One repo. One CI. Reproducible from a cold clone.

</div>

</div>

---

<!-- _class: dense -->

<h3>Why now</h3>

# The deadline for signatures<br>is *31 December 2031*.

<div class="grid">

<div>

**EO 14412** — "Securing the Nation Against Advanced Cryptographic Attacks", 22 June 2026
**OMB M-26-15** — five-phase migration schedule, 24 June 2026

| Date | Requirement |
|---|---|
| 31 Dec 2030 | post-quantum **encryption** |
| **31 Dec 2031** | post-quantum **authentication** |

</div>

<div>

Authentication *is* signatures.

Everything we built sits on the **2031** line.

<br>

> NIST IR 8547 independently deprecates RSA and ECC by 2030, disallows them by 2035.

</div>

</div>

---

<!-- _class: dense -->

<h3>The gap</h3>

# Everyone is protecting the key.<br>Nobody proves the *settlement*.

| Who | Building | Leaves |
|---|---|---|
| Coinbase (23 Jul 2026) | quantum-resistant custody | the key at rest |
| BTQ + QBits | quantum-secure treasury, new chain | requires chain migration |
| PQShield · KETS · InfiniQuant | PQC primitives + hardware | components |

<br>

Native EVM ML-DSA verification: **~500M gas estimated** — Monad's whole block is **150M**. It could not be included at all.

**We measured 1.20M.** Existing chains, no migration, no change to key storage.

> Which makes them channel partners, not incumbents.

---

<!-- _class: dense -->

<h3>Revenue</h3>

# The attestation is<br>the billable unit.

<div class="grid">

<div>

| Line | Price |
|---|---|
| **SDK licence** per institution / yr | **$60–150k** |
| **Per attestation** settled | **$0.02–0.10** |
| **Managed cosigner** hosted, HSM | monthly |

</div>

<div>

Atomic. Countable on-chain by *both* parties. Scales with the customer's volume, not our headcount.

<br>

> Hosted signing ships **after** the audit and HSM custody — not before. Selling it off chmod-600 key files would be malpractice.

</div>

</div>

<br>

**These prices are proposals, not observed. We have sold nothing.**

---

<!-- _class: dense -->

<h3>Market</h3>

# We size bottom-up,<br>because top-down is *noise*.

<div class="grid">

<div>

2026 digital-asset custody "market size", by vendor report:

<code>$0.7T · $793B · $834B · $954B · $1.05T</code>

A 50% spread means they are measuring different things. We will not quote the largest one at you.

</div>

<div>

```
  N institutions × $100k licence
  + attestations × $0.05

  N=250, full        → $25M ARR
  N=250, 4% (10)     → $1.0M ARR
```

**We do not have a defensible N.** Establishing it is the first thing funding buys — and it is a question with a knowable answer.

</div>

</div>

---

<!-- _class: xdense -->

<h3>Traction</h3>

# Zero customers.<br>Zero revenue. No LOIs.

<div class="grid">

<div>

No conversation with any institution has happened. We would rather be marked down for an empty pipeline than imply one we do not have.

</div>

<div>

**What does exist, and is checkable:**
- 4 contracts live on Monad **mainnet**, Monadscan-verified
- one end-to-end run with **real value**
- **279 tests**, 0 skipped
- 2 IBM Heron runs, job IDs + raw counts published
- every documented reviewer command **executed in CI**

</div>

</div>

---

<!-- _class: dense -->

<h3>Go-to-market</h3>

# One design partner,<br>then two channels.

<div class="grid">

<div>

**0–3 months** — one custodian or tokenisation platform. Unpaid, for a public case study. Establishes N and finds whether compliance or engineering holds the budget.

**3–9 months** — channel through the PQC vendors. They sell into our exact buyer and have no settlement story.

</div>

<div>

**6–12 months** — chain-level distribution. Monad and peers have a direct interest in being where PQ settlement is cheapest.

<br>

> Gate on the design partner before spending on either channel. If nobody will sign, the hypothesis is wrong — and we learn that in twelve weeks, not twelve months.

</div>

</div>

---

<!-- _class: xdense -->

<h3>Team</h3>

# Two people.<br>One ships it, one runs it.

<div class="grid">

<div>

**Earvin Gallardo Bravo** — *Founder, engineering*
Wrote the full stack: the Solidity contracts, the SP1 ZK guest program, the hedged PQ signing layer, the QAOA hardware path and the app. Every commit in this repository.

**Brisa Mar Hernández Hernández** — *Operations*
Runs everything outside the codebase — company, operations and delivery. EmpowerTours SAS de CV is incorporated in Mexico.

</div>

<div>

**What we do not have, plainly:**

- no cryptographer on staff — which is why a third-party audit is item **1** of the funding plan, not item 6
- no institutional sales experience — the design-partner phase exists to buy that knowledge, not to fake it
- no dedicated security engineer for HSM key custody

<br>

> Two people shipped four verified mainnet contracts, a ZK circuit, and 279 passing tests. That is the argument for a pilot — and the reason the ask is a counterparty, not headcount.

</div>

</div>

---

<h3>What's next</h3>

# From live mainnet proof to<br>institutional pilot.

<div class="grid">

<div>

**Now → Q3 2026**
- Independent third-party security audit (contracts + PQ/ZK)
- Package as a B2B SDK (wallets, custodians, bridges)
- HSM/KMS-backed key custody

</div>

<div>

**Q4 2026**
- First institutional design-partner pilot
- Hot-path PQ cosigner service
- Paid bug bounty (Immunefi / Code4rena)

</div>

</div>

---

<!-- _class: title dense -->

<div class="pill">The Ask</div>

# A 12-week paid pilot.<br>Not a cheque.

## One asset flow. Agreed pass/fail criteria. **$75–120k** — sized to fund a scoped audit of the settlement path, not the full-stack engagement.

<div class="grid">

<div>

**We will have failed if** any settlement instruction cannot be tied on-chain to the exact PQ-signed order that authorised it, within the agreed gas and latency budget — and we will report it that way.

</div>

<div>

Our binding constraint is not capital. The mainnet deploy cost trivial gas and is already done.

It is the absence of an institutional counterparty willing to define what *good* looks like.

</div>

</div>

<br>

<code>github.com/EmpowerTours/quantum-portfolio</code> · commit <code>9727322</code>
