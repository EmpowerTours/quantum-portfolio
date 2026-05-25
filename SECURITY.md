# Security model — Quantum-Safe DeFi Trading Agents

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

The canonical JSON encoding of this dictionary is signed with **ML-DSA-65
(NIST FIPS 204)** — the lattice-based digital signature scheme NIST
finalised in 2024 for post-quantum protection. ML-DSA-65 keys are 1952 B
(public) and 4032 B (secret); signatures are at most 3309 B. The library
used is `dilithium-py`, a pure-Python reference implementation; for
production deployment we would swap to a C-backed equivalent (`liboqs`)
for ~10× speed.

This means:
- **Tampering**: changing any field of the order — pool list, weights,
  QPU job ID — invalidates the signature. The test suite verifies this.
- **Replay**: the agent maintains a set of seen nonces from
  `outputs/audit_log.jsonl` and refuses to sign an order whose nonce has
  already been used.
- **Forgery**: forging a signature without the secret key requires
  breaking ML-DSA-65, which is conjectured infeasible even against a
  cryptographically relevant quantum computer.

### Quantum-resistant signing of the off-chain audit trail
`outputs/audit_log.jsonl` is an append-only JSON-lines file recording
every signed order. Each line carries the signature, the public key, the
SHA-256 digest of the canonical payload, and the verification status at
the time of signing. The log itself is not signed in this version — a
follow-up step would chain entries (each line includes the previous
line's SHA-256) for tamper-evident sequencing.

### Secret-key file mode
The ML-DSA-65 secret key is persisted to `keys/pq.sec` with mode `0600`
(owner read/write only). The path is gitignored. The public key
(`keys/pq.pub`) is world-readable so reviewers can verify orders without
the secret.

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
on-chain Monad transaction that *executes* the order. That requires a
chain-level PQ signature scheme, which is outside the scope of this MVP.

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
For a production deployment we would store the ML-DSA secret key in a
hardware security module (HSM) or secure enclave, not a chmod-600 file.

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

All artefacts are produced deterministically (modulo ML-DSA's hedged
randomness in `sign`).
