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
| **Guest execute** (real mainnet order) | verified in zkVM; committed `orderHash 0xf9e798a1…d3c3` (matches the on-chain anchored order) |
| zkVM cycles (baseline) | 3,038,634 |
| zkVM cycles (**keccak precompile**, `vendor/keccak`) | **1,876,372** (−38%) |
| **Core proof generation + verification** | **GENERATED and VERIFIED locally** on this 15 GB box (peak RSS 14.75 GB) — succeeds *because* of the precompile patch (baseline OOM'd at 3.04M cycles). |
| Program vkey | `0x002449ce46906836090ce01e18c768372c80b62cd95c39360b9e070d91293b65` |
| Groth16 wrap (for on-chain) | needs more memory than the core proof (gnark witness) → a GPU / >=32 GB box or the Succinct prover network. One command (`cargo run --bin evm -- --system groth16`). |

The circuit, the real-order verification, **and a real STARK proof** are all
done locally. The only remaining step for on-chain use is the Groth16 wrap,
which is heavier than the core proof and wants a bigger box.

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

`mldsa_input.json` is the real `(pk, canonical order bytes, signature)` exported
from `outputs/mainnet_route_order.json` via `src/pq_signing.py:canonical_bytes`.

## Finish it (Groth16 proof + on-chain) on adequate hardware

1. On a >=32 GB machine or the **Succinct prover network** (`NETWORK_PRIVATE_KEY`):
   ```bash
   cargo run --release --bin evm -- --system groth16   # writes the proof + fixture
   ```
2. Deploy the SP1 Groth16 verifier (from `succinctlabs/sp1-contracts`) on Monad
   mainnet, then deploy `MLDSAAttestation(verifier, 0x002449ce…3b65)`.
3. Call `attest(publicValues, proofBytes)` -> the proof verifies on-chain
   (~230k gas) and `orderHash 0xf9e798a1…` is recorded as PQ-attested.

## Numbers for the pitch (independently citeable)

- Prior art (SP1 Dilithium verifier): ~22 s proofs, ~260-byte on-chain proof.
- This build: real ML-DSA-65 verification of the **mainnet-settled order** runs
  provably in the zkVM (3.04M cycles); on-chain check ~230k gas via Groth16.
- Honest: no quantum advantage anywhere here; this is the PQ-*settlement* path,
  moving a 500M-gas EVM verification into a succinct proof.
