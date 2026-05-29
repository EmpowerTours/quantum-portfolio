# Security model — Quantum-Safe DeFi Allocation Agents

This document is intentionally specific about *what is protected* and
*what is not* by the current implementation. It is meant for a Santander X
panel reviewer who wants to know whether the pitch's "quantum-safe"
language matches the code.

## What the code currently protects

### Rebalance-order integrity and authenticity
Every rebalance decision is wrapped in a JSON `RebalanceOrder` containing:

- `pools`, `weights`, `expected_return`, `expected_vol`
- `qpu_job_id` (when present) linking back to the IBM Quantum hardware run
- `qaoa_p_optimal` for the same
- `order_id`, `nonce` (both UUID4), `issued_at` (ISO-8601 UTC)
- `agent_id`

The canonical JSON encoding of this dictionary is signed with **three
independent signature schemes** — the standard hybrid-PQ hedge
construction (one lattice + one hash-based + one classical) with
disjoint security assumptions:

| Scheme | Standard | Sizes (pk / sig) | Security assumption |
|---|---|---|---|
| **ML-DSA-65** | NIST FIPS 204 (2024) | 1952 B / 3309 B | Module-LWE / MSIS (lattice) |
| **SLH-DSA-SHAKE-256s** | NIST FIPS 205 (2024), Level-5 | 64 B / ~29 KB | SHA-3 collision resistance |
| **Ed25519** | RFC 8032 | 32 B / 64 B | Curve25519 discrete log |

Implementation is `quantcrypt` 1.0+ (PQClean-bound) for the two PQ
schemes and pyca's `cryptography` for Ed25519. Backend choice is
deliberate: PQClean is the reference C implementation underneath LF
PQCA's `liboqs`; shipping precompiled binaries removes the C-toolchain
dependency at install time without abandoning the audited reference
code. Same NIST FIPS 204 algorithm NEAR Protocol committed to at L1
on 2026-05-06, with Q2 2026 testnet rollout planned — the first major
L1 to commit to a NIST-finalised PQ signature option at the account
layer, and the strongest available signal that the standardised stack
we sign with is on a production-deployment trajectory.

This means:
- **Tampering**: changing any field of the order — pool list, weights,
  QPU job ID — invalidates ALL THREE signatures. The test suite verifies
  this (`test_hedged_tamper_breaks_all_signatures`).
- **Replay**: the agent maintains a set of seen nonces from
  `outputs/audit_log.jsonl` and refuses to sign an order whose nonce has
  already been used.
- **Forgery**: forging a hedged order requires breaking the Module-LWE
  lattice problem AND the SHA-3 collision resistance AND the Ed25519
  discrete log. Each assumption is independent; a breakthrough against
  any one of them still leaves the other two as defence in depth.

### Quantum-resistant signing of the off-chain audit trail
`outputs/audit_log.jsonl` is an append-only JSON-lines file recording
every signed order. Each line carries the signature, the public key, the
SHA-256 digest of the canonical payload, the verification status at the
time of signing, **and a `prev_hash` field linking it to the SHA-256 of
the previous line**. The first entry's `prev_hash` is the genesis
sentinel (64 zeros). `verify_audit_chain()` walks the file and rejects
the log if any line's `prev_hash` does not match the SHA-256 of the
previous serialised line — i.e. **deletions, reorderings, and middle
edits are detected**. Append-only forward-extension is the only mutation
that preserves the chain.

### Schema versioning
Every signed `RebalanceOrder` carries a `schema_version` integer that is
itself part of the signed payload. Adding or renaming fields bumps the
constant. An order signed under schema 1 cannot be re-purposed as if it
were schema 2 — the signature covers the version.

### Strict canonicalisation
`canonical_bytes` rejects non-JSON-native types (`datetime`, `Decimal`,
custom classes) rather than silently coercing them via `default=str`.
This prevents the subtle bug where a sender's stringification differs
from a receiver's, breaking verification.

### Two-key custody (intentional design)
A rebalance is authorised by two independent signing layers:

  1. **Agent's hedged intent signature** — ML-DSA-65 + SLH-DSA + Ed25519
     over the off-chain order. This is what the audit log preserves and
     what survives Q-Day. Three independent assumptions; an attacker
     breaking one of them still cannot forge intent.
  2. **Wallet's ECDSA secp256k1** signs the on-chain **custody** TXs —
     the anchor and the vault deposit on Monad. The agent never holds
     the wallet's key. The on-chain leg is custody + audit-event, not
     trade execution (see SUBMISSION.md "What this is and is not").

Either layer alone is insufficient: intent-without-wallet cannot reach
the chain; wallet-without-intent has no Q-Day-resistant audit trail. An
attacker who steals only the agent's keys cannot move funds; one who
steals only the wallet key cannot forge an authentic audit history.

### Secret-key file modes
All three secret keys are persisted under `keys/` with mode `0600`
(owner read/write only) — `pq.sec` (ML-DSA-65), `slh.sec` (SLH-DSA),
`ed25519.sec` (Ed25519). All `keys/*` paths are gitignored. The
public-key counterparts are world-readable so reviewers can verify
orders without the secrets.

### IBM Quantum token
The `IBM_QUANTUM_TOKEN` is loaded from `.env` (mode `0600`, gitignored).
It is never logged and never embedded in committed code.

## What the code does NOT protect

### On-chain transaction signatures still use ECDSA
Monad, like every other production EVM chain in 2026, signs transactions
with secp256k1 ECDSA. Shor's algorithm on a cryptographically relevant
QPU breaks ECDSA. **This is the "Q-Day" risk we are *preparing for*, not
eliminating.** The PQ signature we attach to the *order* is meaningful
because:

1. It binds the agent's intent to the QPU result, which an attacker
   cannot forge or replay even with a Q-Day-capable adversary.
2. It establishes a verifiable audit trail that survives Q-Day even if
   the underlying ECDSA signatures eventually become forgeable.
3. When EVM chains adopt PQ signatures (Monad's roadmap or otherwise),
   the agent's ML-DSA layer can be re-used directly.

It does NOT prevent a future Q-Day-capable attacker from forging the
on-chain Monad transaction that *anchors and escrows* the order. That
requires a chain-level PQ signature scheme, which is outside the scope
of this MVP.

### Off-chain data sources are trusted-but-not-verified
Pool yield data is fetched from the public DeFiLlama API
(`https://yields.llama.fi`) over TLS but with no authentication beyond
the TLS handshake. A successful man-in-the-middle or upstream data
poisoning would feed manipulated yields into the optimiser. Production
deployment would require either (a) a multi-source consensus check, or
(b) an on-chain oracle (Pyth, Chainlink) with cryptographic proofs.

### AI forecast layer has no adversarial robustness
The Ridge regressor is trained on historical price/yield features with
walk-forward, no lookahead. It has no defense against adversarial inputs
(if someone could control the feature stream they could steer
predictions). This is research-grade; not exploitable at the current
scope.

### The agent's private key is on disk, not in an HSM
For a production deployment we would store the ML-DSA, SLH-DSA, and
Ed25519 secret keys in a hardware security module (HSM) or secure
enclave, not chmod-600 files. The PQClean reference implementation
underlying `quantcrypt` is constant-time at the C layer, but a Python
process running on a multi-tenant host can still leak via process
memory dumps, side-channel observation of allocation patterns, or
swap-file persistence. The threat model documented here assumes the
agent runs on a single-tenant machine the operator controls. HSM
migration is funded line item #4 in `SUBMISSION.md`'s "What would
happen with funding" section.

### MonadAllocationVault accepts ANY 32-byte hash from ANY caller
The vault's `execute(bytes32 orderHash, ...)` makes no on-chain check
that `orderHash` corresponds to a real PQ-signed RebalanceOrder — the
contract has no way to do this, since ML-DSA verification on-chain
costs ~500M gas. **An attacker can spend their own gas to call
`execute` with a garbage `orderHash`, polluting the on-chain
`Allocated` event stream with hashes that do not appear in any
shipped `signed_orders.json`.** This is by design:
- It does not let the attacker steal deposits — deposits are keyed
  by `(msg.sender, orderHash)`, so the attacker can only pollute
  their own slot.
- It does not let the attacker forge the agent's history — the
  agent's `orderHash` collision space is 2²⁵⁶ and the indexer's
  filter (Allocated event topic[1] == agent's wallet address) is
  msg.sender-scoped.
- It does cost the attacker gas, so the attack is grief-only, not
  cheap-spam.
- The off-chain `outputs/signed_orders.json` + `outputs/audit_log.jsonl`
  remain the source of truth for "what orderHashes correspond to
  real agent decisions". The on-chain log is an *anchor*, not the
  primary record.

A reviewer who wants to assert "the agent made decision X" must:
1. Find the order in `signed_orders.json` whose SHA-256 = X.
2. Run `verify_signed_order(...)` — must return True under all three
   PQ schemes.
3. Confirm the on-chain `Allocated` event topic[2] = X and topic[1]
   = the agent's wallet address.

Skipping step (1) or (2) means trusting the on-chain log alone, which
is not safe for the attacker-polluted-vault case.

### Streamlit binding
The Streamlit UI binds to `127.0.0.1:8501` by default (see
`.streamlit/config.toml`). It is not exposed to the public internet. If
deployed remotely, place behind a reverse proxy with TLS + auth.

## Threat model summary

| Adversary | Capability | Defended? |
|---|---|---|
| Casual observer | reads the public network | yes — TLS to IBM + DeFiLlama, no plaintext secrets |
| Repo cloner | reads the GitHub repo | yes — secret key + IBM token are gitignored |
| Local attacker with FS read | reads chmod-600 files | partial — they get the secret key but PQ-signed history is still tamper-evident |
| Replay attacker | resubmits a recorded order | yes — nonce check rejects |
| Order tamperer | mutates a signed order in transit | yes — ML-DSA verify fails |
| Q-Day quantum attacker (off-chain) | breaks ECDSA via Shor | yes (for the agent → order path) |
| Q-Day quantum attacker (on-chain) | forges a Monad transaction | NO — outside MVP scope, awaits chain-level PQ |
| Data poisoner at DeFiLlama | manipulates yield feed | no — needs multi-oracle consensus, planned |
| Insider with HSM access | extracts the agent's PQ secret key | no — needs an HSM, planned |

## Reproducing the PQ artefacts

```sh
# Run the QAOA hardware demo (needs IBM Quantum credentials)
python run_hardware.py

# Sign the resulting order with ML-DSA-65
python run_pq_demo.py

# Verify the signature
python -c "from src import orders; \
  [print('verified:', orders.verify_signed_order(s)) \
   for s in orders.load_signed_orders()]"

# Run the test suite
python tests/test_pq_signing.py
```

**Reproducibility scope.** The signature *verification* is fully
deterministic — a reviewer running `verify_signed_order` against the
shipped `outputs/signed_orders.json` gets True. The signature
*generation*, however, is non-deterministic by design:
- ML-DSA uses internal hedged randomness on every sign call;
- the agent generates fresh ML-DSA + SLH-DSA + Ed25519 keypairs on
  first run if `keys/` is empty;
- each `RebalanceOrder` carries a fresh UUID4 `nonce` and `order_id`
  and a current-time `issued_at`.

A fresh clone running `run_pq_demo.py` therefore produces a
**different `outputs/signed_orders.json` than what we shipped**,
with a different SHA-256 and a different embedded public key. To
verify *the shipped artefact*, do not re-run `run_pq_demo.py` first
(see SUBMISSION.md "Path A" vs "Path B"). To verify *the pipeline*,
do re-run it — and broadcast your own anchor + vault TXs from your
own wallet if you want a complete on-chain trail.
