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

> Harvest now. Decrypt later. The adversary already has your 2026 trade orders — they just haven't broken the curve yet.

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

<h3>The Quantum Layer</h3>

# QAOA on real hardware,<br>reported with statistical honesty.

<div class="grid">

<div>

- Executed on **IBM Heron r2** (`ibm_marrakesh`) via Qiskit Runtime, 4 096 shots,
  raw and error-mitigated (XY4 DD + measurement twirling). Job IDs shipped in
  `outputs/hardware_run_defi.json`.
- **n = 1 per arm.** We report Wilson 95% CIs and a Fisher exact test, and they
  do not separate: the DeFi run is 15 vs 15 successes, p = 1.000.
- **Uniform random on 8 qubits expects 16 / 4 096.** Our DeFi run returned 15.
  We do not claim the QPU optimised anything in it. The stocks run sits ~2.8σ
  above chance. Replication (n ≥ 10) is a funded milestone, not a result.

</div>

<div class="card">

<h3>What this is, honestly</h3>

QAOA is **not** yet faster than SLSQP for this problem size. We measure the **gap** as it closes. Honest measurement is the deliverable.

</div>

</div>

---

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

<h3>The Provenance Layer</h3>

# A hash chain the vault<br>refuses to disobey.

<div class="grid">

<div>

1. Agent builds order. PQ-signs it.
2. <code>AuditAnchor.anchor(orderHash)</code> on Monad. Links to caller's previous hash.
3. <code>RoutingVault.executeAndRoute(orderHash, …)</code> refuses execution unless <code>ANCHOR.lastHash[msg.sender] == orderHash</code>.

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

<h3>Proof, not promises</h3>

# Live on Monad MAINNET.<br>235 tests. ZK-verified.

<div class="grid-3">

<div>
<div class="big">4<small>contracts live<br>Monadscan-verified</small></div>
</div>

<div>
<div class="big">235<small>tests passing<br>93 Python + 142 Foundry</small></div>
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

<h3>The end-to-end demo — real value, one hash</h3>

# QPU decision → PQ signature<br>ZK-verified on-chain → yield.

<table>

<tr><th>Step</th><th>Contract</th><th>What happened (Monad mainnet)</th></tr>
<tr><td>1. Attest</td><td><a href="https://monadscan.com/address/0xb0aadafe68647578520e988b4444e556c300b4da"><code>MLDSAAttestation</code></a></td><td>Order's <strong>ML-DSA-65 signature verified on-chain via ZK proof</strong> (~230k gas, not ~500M); <code>pqAttested = true</code></td></tr>
<tr><td>2. Anchor</td><td><a href="https://monadscan.com/address/0x8422b555dce11913a4657c2f47c839637fc71ffd"><code>AuditAnchorV2</code></a></td><td>Hash <code>0xd8bf1551…15f9</code> committed, immutable</td></tr>
<tr><td>3. Swap</td><td><a href="https://monadscan.com/address/0x06f233062ee23590e5cc873df511024f3d981e56"><code>UniswapRoutingVault</code></a></td><td>0.1 MON → <strong>2,123 USDC</strong> via live Uniswap v3, anchor-gated</td></tr>
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

<!-- _class: title -->

<div class="pill">The Ask</div>

# Pilot with Santander.

## Q-Day-resistant crypto exposure for institutional treasury,<br>on rails we can prove are honest.

<br>

<code>github.com/EmpowerTours/quantum-portfolio</code> · commit <code>33b69dd</code>
