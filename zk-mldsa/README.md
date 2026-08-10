# zk-mldsa — ML-DSA-65 verification in a zkVM, verifiable on-chain

The Q-Day gap in the on-chain leg was: the audit trail is post-quantum
(ML-DSA-65) but the on-chain settlement TX is secp256k1, and verifying ML-DSA
directly in the EVM is estimated at ~500M gas — more than three times Monad's
entire 150M block gas limit, so it cannot be included at all. This closes that
gap the **buildable** way: run the lattice verification off-chain in the **SP1
zkVM** and check a Groth16 proof on-chain for a **measured 1 196 224 gas**.

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
| Groth16 wrap (for on-chain) | **DONE 2026-07-30** on a 64 GB box (~$0.32). 356-byte proof, vkey `0x00ed29f3…cbd5`, 64-byte publicValues. Verified on-chain by SP1's Monad verifier and consumed by `attest()`. |

### Status: the fixture is CURRENT and deployed

`contracts/src/fixtures/groth16-mldsa-fixture.json` proves the ML-DSA-65
signature over orderHash `0xaee5fdf0…3ee9` — the same order anchored and
swapped on Monad mainnet — by the live signing key `ac0b2aea…`.

| | |
|---|---|
| publicValues | 64 bytes = `(orderHash, pkHash)` |
| vkey | `0x00ed29f3eb27b863b25c2619776ecc56c8c84e90b7da27250c8317cc2758cbd5` |
| proof | 356 bytes, selector `0x4388a21c` |
| Deployed to | `MLDSAAttestation` [`0xb0aADaFe68647578520E988b4444e556c300b4Da`](https://monadscan.com/address/0xb0aadafe68647578520e988b4444e556c300b4da) |
| `attest()` | [`0x12b7cd0c…7429`](https://monadscan.com/tx/0x12b7cd0cdda7b4d2c2a5b049e71265e6464c286e643a5524ee3825ef1f277429), 1 196 224 gas |

An *earlier* fixture was unusable in three ways — 32-byte single-field
publicValues, the superseded vkey `0x00eddc1f…8c37`, and a signature by the
ML-DSA key `8a1b08d1…` whose secret half was lost. Because `verifier`,
`mldsaProgramVKey` and `agentPkHash` are all `immutable`, deploying against it
would have been a permanent write-off. `script/DeployMLDSAAttestation.s.sol`
rejects all three cases before broadcasting and re-verifies the proof on-chain
after deploying.

### The vkey IS reproducible — verify it yourself

The program vkey is a hash of the compiled guest ELF, and `MLDSAAttestation`
pins it as an immutable. Three commands confirm the contract on Monad runs the
program in this directory:

```bash
cd zk-mldsa/script
cargo build --release          # compiles inside ghcr.io/succinctlabs/sp1:v6.3.1
cargo run --release --bin vkey # 0x00ed29f3eb27b863b25c2619776ecc56c8c84e90b7da27250c8317cc2758cbd5

cast call 0xb0aADaFe68647578520E988b4444e556c300b4Da \
  "mldsaProgramVKey()(bytes32)" --rpc-url https://rpc.monad.xyz
# same value
```

Guest ELF SHA-256: `87ece7e02e2464947a30399983346d2da7a8182f176c065e5635414ea138a376`

**This was not always true, and the fix is worth stating.** `script/build.rs`
called `build_program_with_args("../program", Default::default())`, and
`sp1_build::BuildArgs.docker` defaults to `false` — so the guest compiled
against whatever toolchain the host happened to have. `rust-toolchain` also
pinned `channel = "stable"`, a moving target. Identical source produced
`0x00ed29f3…` on the proving box and `0x00364772…` on a dev box, and only the
former verified on chain.

Both are now pinned: `docker: true` with `tag: "v6.3.1"` (the resolved
`sp1-build` version, not the `6.0.1` floor in `Cargo.toml`), and
`channel = "1.90.0"`. The match above is therefore deterministic rather than
coincidental — which matters, because the vkey IS the on-chain identity of the
program and a silent toolchain bump would change it.

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
   (**1 196 224 gas measured**, from the receipt of tx `0x12b7cd0c…7429`)
   and the orderHash is recorded as PQ-attested.

## Numbers for the pitch (independently citeable)

- Prior art (SP1 Dilithium verifier): ~22 s proofs, ~260-byte on-chain proof.
- This build: real ML-DSA-65 verification of the **mainnet-settled order** runs
  provably in the zkVM (3.04M cycles); the on-chain check is a Groth16 proof at
  a **measured 1 196 224 gas**. Earlier drafts of this file said ~230k, which
  was never measured — the figure above comes from the transaction receipt.
- Honest: no quantum advantage anywhere here; this is the PQ-*settlement* path,
  moving a 500M-gas EVM verification into a succinct proof.
