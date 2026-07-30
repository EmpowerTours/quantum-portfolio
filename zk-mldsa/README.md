# zk-mldsa — ML-DSA-65 verification in a zkVM, verifiable on-chain

The Q-Day gap in the on-chain leg was: the audit trail is post-quantum
(ML-DSA-65) but the on-chain settlement TX is secp256k1, and verifying ML-DSA
directly in the EVM costs ~500M gas (infeasible). This closes that gap the
**buildable** way — run the lattice verification off-chain in the **SP1 zkVM**
and check a ~230k-gas Groth16 proof on-chain.

## What it does

- **Guest** (`program/`): reads a real ML-DSA-65 `(public key, canonical order
  bytes, signature)` and verifies the signature *inside the zkVM* using the
  pure-Rust `ml-dsa` crate. On success it commits `SHA-256(order)` — the same
  `orderHash` the pipeline anchors on-chain. Invalid signatures panic, so a
  proof can only exist for a genuine signature.
- **Host** (`script/`): feeds the real triple exported from the pipeline
  (`mldsa_input.json`) and runs execute or prove.
- **On-chain** (`contracts/src/MLDSAAttestation.sol`): verifies the SP1 Groth16
  proof and records `orderHash` as PQ-attested — a permanent on-chain statement
  that the order carries a valid ML-DSA-65 signature. AuditAnchor / the vault /
  the Morpho adapter can gate on `pqAttested[orderHash]` for quantum-safe
  settlement.

## Status (measured on this machine)

| Step | Result |
|---|---|
| Cross-library compat (quantcrypt sig ↔ RustCrypto `ml-dsa`) | verifies |
| **Guest execute** (current signing key) | verified in zkVM 2026-07-29; committed `orderHash 0xab308fe8…60a2` **and** `pkHash 0xac0b2aea…02ad` |
| zkVM cycles (baseline) | 3,038,634 |
| zkVM cycles (**keccak precompile**, `vendor/keccak`) | **2,036,177** (−33%) |
| **Core proof generation + verification** | **GENERATED and VERIFIED locally** on this 15 GB box (peak RSS 14.75 GB) — succeeds *because* of the precompile patch (baseline OOM'd at 3.04M cycles). |
| Program vkey | `0x00364772d1d557782109c04c8041ea0b05fb55705356a621d37c35d6ecdaba72` |
| Groth16 wrap (for on-chain) | **NOT YET REGENERATED** — see below. Needs a ≥32 GB box; the wrap's memory need is roughly fixed regardless of guest cycles. |

### The committed fixture is STALE — do not deploy against it

`contracts/src/fixtures/groth16-mldsa-fixture.json` was generated before two
changes and is now unusable in three independent ways:

1. its `publicValues` is **32 bytes**, the old orderHash-only layout; the guest
   now commits `(orderHash, pkHash)` and the contract decodes **64**;
2. its `vkey` is the superseded `0x00eddc1f…8c37`;
3. it proves a signature by ML-DSA key `8a1b08d1…`, **whose secret half was
   lost**. The live identity is `ac0b2aea…` (`keys/pq.pub`).

Because `verifier`, `mldsaProgramVKey` and `agentPkHash` are all `immutable`
with no owner and no setter, deploying against it would be a permanent
write-off. `script/DeployMLDSAAttestation.s.sol` now refuses all three cases
before broadcasting, and re-verifies the proof on-chain after deploying.

**To regenerate:** the guest input has already been re-exported from an order
signed by the current key (`python zk-mldsa/export_mldsa_input.py`), and the
guest executes cleanly against it. Only the Groth16 wrap remains — run
`provision.sh` on a ≥32 GB box, or use the Succinct prover network.

Nothing else in the system depends on this: `AuditAnchorV2`,
`UniswapRoutingVault` and `MorphoSupplyAdapter` contain no reference to
`MLDSAAttestation`, so the core pipeline deploys and runs without it.

### The precompile optimization (`vendor/keccak`)

ML-DSA's SHAKE runs through the `shake` → `keccak` crates. We vendored `keccak`
v0.2.0 and patched `with_p1600` so the full Keccak-f[1600] permutation calls
SP1's `syscall_keccak_permute` precompile inside the zkVM (`[patch.crates-io]`
in the workspace `Cargo.toml`). That single change cut cycles 38% and brought
core proving under the 15 GB ceiling.

## Reproduce the execute (no proving)

```bash
export PATH="$HOME/.sp1/bin:$PATH" PROTOC="$HOME/.local/protoc/bin/protoc"
cd zk-mldsa/script
cargo run --release --bin fibonacci -- --execute --input ../mldsa_input.json
```

`mldsa_input.json` is the real `(pk, canonical order bytes, signature)`. Generate
it with:

```bash
python zk-mldsa/export_mldsa_input.py --order outputs/signed_orders.json --index 0
```

That exporter **refuses** to emit an input unless the order was signed by the
key currently in `keys/pq.pub` and the signature re-verifies — which is exactly
the check whose absence produced a fixture for a key that was later lost. No
secret material is read or written: the guest input is `(public key, message,
signature)`, all public, which is what makes it safe to carry to a rented
proving box.

## Finish it (Groth16 proof + on-chain) on adequate hardware

1. On a >=32 GB machine or the **Succinct prover network** (`NETWORK_PRIVATE_KEY`):
   ```bash
   cargo run --release --bin evm -- --system groth16   # writes the proof + fixture
   ```
   `provision.sh` does the whole box setup in one shot.
2. Deploy the SP1 Groth16 verifier (from `succinctlabs/sp1-contracts`) on Monad
   mainnet — or reuse the live gateway at
   `0x7DA83eC4af493081500Ecd36d1a72c23F8fc2abd` — then:
   ```bash
   SP1_VERIFIER=0x7DA83eC4af493081500Ecd36d1a72c23F8fc2abd \
   AGENT_PK_HASH=0xac0b2aea57e0d9188717e9dada2042a60e2cae45bff90eccde9c1be13f5702ad \
   forge script script/DeployMLDSAAttestation.s.sol --rpc-url https://rpc.monad.xyz
   ```
   The script reads the vkey from the fixture, rejects a stale layout or a
   wrong signer before broadcasting, and calls `isValidProof` against the
   deployed contract afterwards — so a bricked deployment fails loudly at
   deploy time rather than on first use.
3. Call `attest(publicValues, proofBytes)` -> the proof verifies on-chain
   (~230k gas) and the orderHash is recorded as PQ-attested.

## Numbers for the pitch (independently citeable)

- Prior art (SP1 Dilithium verifier): ~22 s proofs, ~260-byte on-chain proof.
- This build: real ML-DSA-65 verification of the **mainnet-settled order** runs
  provably in the zkVM (3.04M cycles); on-chain check ~230k gas via Groth16.
- Honest: no quantum advantage anywhere here; this is the PQ-*settlement* path,
  moving a 500M-gas EVM verification into a succinct proof.
