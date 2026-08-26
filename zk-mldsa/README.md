# zk-mldsa — ML-DSA-65 verification in a zkVM, verifiable on-chain

The Q-Day gap in the on-chain leg was: the audit trail is post-quantum
(ML-DSA-65) but the on-chain settlement TX is secp256k1, and verifying ML-DSA
directly in the EVM costs **8.1M gas** (NIST-compliant) or **4.9M**
(ZKNoxHQ's optimised ETHDilithium) — both measured by `make bench` in
[ZKNoxHQ/ETHDILITHIUM](https://github.com/ZKNoxHQ/ETHDILITHIUM), KAT-passing and
deployed on Sepolia under the Ethereum Foundation's Kohaku project. That fits in
a Monad block; it is simply expensive. This closes the gap the cheaper way: run
the lattice verification off-chain in the **SP1 zkVM** and check a Groth16 proof
on-chain for a **measured 1 192 295 gas** — 6.8x cheaper than native NIST ML-DSA
and 4.1x cheaper than ETHDilithium.

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
| Program vkey | `0x00ed29f3eb27b863b25c2619776ecc56c8c84e90b7da27250c8317cc2758cbd5` — pinned as an immutable by MLDSAAttestation; see the reproducibility note below |
| Groth16 wrap (for on-chain) | **DONE 2026-07-30** on a 64 GB box (~$0.32). 356-byte proof, vkey `0x00ed29f3…cbd5`, 64-byte publicValues. Verified on-chain by SP1's Monad verifier and consumed by `attest()`. |

### Status: the fixture is CURRENT and deployed

`contracts/src/fixtures/groth16-mldsa-fixture.json` proves the ML-DSA-65
signature over orderHash `0x8fdc0057…d3de` — the same order anchored and
swapped on Monad mainnet — by the live signing key `ac0b2aea…`.

| | |
|---|---|
| publicValues | 64 bytes = `(orderHash, pkHash)` |
| vkey | `0x00ed29f3eb27b863b25c2619776ecc56c8c84e90b7da27250c8317cc2758cbd5` |
| proof | 356 bytes, selector `0x4388a21c` |
| Deployed to | `MLDSAAttestation` **v1**, superseded 2026-08-25 by [MLDSAAttestationV2](https://monadscan.com/address/0xfeef24a5dbf43e9de8ac0d0eab0f0141e980a52c) but still holding this attestation: [`0xb0aADaFe68647578520E988b4444e556c300b4Da`](https://monadscan.com/address/0xb0aadafe68647578520e988b4444e556c300b4da) |
| `attest()` | [`0xcd37af90…8688`](https://monadscan.com/tx/0xcd37af90ca043ee2da205855433d8c9cda9fb0466dd01df2d78224f44ed98688), 1 192 295 gas |

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

# V2 carries the same vkey; the superseded v1 at 0xb0aADaFe…b4Da returns it too.
cast call 0xFeEf24A5dBF43E9dE8AC0d0EaB0f0141E980A52c \
  "mldsaProgramVKey()(bytes32)" --rpc-url https://rpc.monad.xyz
# same value
```

Guest ELF SHA-256: `d82d45eed9f1388d20079446be4acc695cfe99f9ab168b9847c26188ac61c902`

**The guest is consensus-critical bytes, not source, and this page said the
wrong thing about why for 24 days.** It previously claimed that identical
source had produced different vkeys on different machines, and that pinning
`docker: true` with `tag: "v6.3.1"` plus `channel = "1.90.0"` had fixed a
toolchain nondeterminism. Measured on 2026-08-26, that diagnosis was wrong in
both directions. The build is deterministic and was already: the same source
produces a byte-identical ELF across machines and across the docker and
non-docker paths. The three vkeys this repo has seen are three different
**source states**, not three toolchains.

| ELF SHA-256 | vkey | source state |
|---|---|---|
| `87ece7e0…a376` | `0x00364772…ba72` | before `7ea4020` (2026-07-28) |
| `d82d45ee…c902` | `0x00ed29f3…cbd5` | `7ea4020`..`1e2ec67^` — **what the chain pins** |
| `eccfe103…7faf` | `0x00aa9611…c169` | after `1e2ec67` |

The third one is the lesson. Commit `1e2ec67` rewrote the `//!` doc comment at
the top of `program/src/main.rs` from three lines to four, to correct a gas
figure. It changed no logic and no string any code reads. But
`.expect("ML-DSA-65 verification failed")` embeds a
`core::panic::Location { file, line, col }` as static data, so shifting every
line below it down by one changed the ELF, the vkey, and therefore the
on-chain identity of the program. `mldsaProgramVKey` is `immutable`, so every
proof built from that guest reverts in `attest()`. It went unnoticed until a
freshly proved fixture would not verify — after a proving box had been paid
for. The correction now carries the same figure in three lines instead of
four, which restores the ELF byte for byte.

The pins are kept: pinning the image and the toolchain is still the right
default, and it costs nothing. They are simply not what makes this
reproducible. What protects the vkey now is a gate rather than a claim —
`verify_claims.py` pins a digest over every guest build input, asserts each
shipped Groth16 fixture carries the pinned vkey, and with `--chain` compares
that vkey against `mldsaProgramVKey()` on both attestations. `--rebuild-guest`
rebuilds and re-derives it. `tests/test_verify_claims.py` proves the digest
actually moves when a comment line is added, so the gate cannot go blind to
the exact defect it was written for.

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
   (**1 192 295 gas measured**, from the receipt of tx `0xcd37af90…8688`)
   and the orderHash is recorded as PQ-attested.

## Key rotation (`MLDSAAttestationV2`)

`MLDSAAttestation` v1 — superseded, but still on chain at
`0xb0aADaFe68647578520E988b4444e556c300b4Da` — pins one `agentPkHash`,
`immutable`, no setter. The executors pin `PQ()`
`immutable` in turn. So changing the agent identity means redeploying the
attestation contract **and** both executors. That is the same "authentication
cannot be upgraded without abandoning the address" problem the Monad
[flexible-and-upgradeable-account-authentication](https://forum.monad.xyz/t/flexible-and-upgradeable-account-authentication/526/1)
MIP is written against, and it is not hypothetical here: the 2026-07-12 signing
identity `8a1b08d1…` was lost outright, which under v1 is unrecoverable by
construction.

`contracts/src/MLDSAAttestationV2.sol` replaces the single pinned key with a
**set** of authorised keys, reconfigurable by two paths with deliberately
different powers. **Live on Monad mainnet at
`0xFeEf24A5dBF43E9dE8AC0d0EaB0f0141E980A52c`** since 2026-08-25 (block
99109468), and both executors were redeployed the same day to gate on it:
`UniswapRoutingVault` `0xcC60db5E123Cb3150d5F11CA5526a79B4f31113F` and
`MorphoSupplyAdapter` `0x6D42fA32880aDd1d794abBF98c5Cd104Fe332D89`. The
migration cost 0.5702 MON in total. The proof transactions cited above were
re-run against this pair on 2026-08-26, from fresh ML-DSA signatures and fresh
Groth16 proofs, so the evidence and the live contracts are the same set. The
earlier run on the retired pair is preserved in `outputs/archive/`.

**It reuses the existing proving stack unchanged.** The guest commits
`(sha256(msg), sha256(pk))` for an *arbitrary* message — nothing in it is
order-specific — so a reconfiguration statement is proven by the same guest,
the same vkey and the same Groth16 verifier as an order. No new circuit, no
re-proving of anything, no new vkey.

| Path | Who | Speed | Can |
|---|---|---|---|
| PQ | a currently authorised ML-DSA key, via a Groth16 proof | instant | add a key, revoke a key, veto a recovery, replace the guardian |
| Guardian | the `guardian` address | `recoveryDelay` (2–30 days), vetoable | **add a key only** |

The guardian can never revoke, never attest, and never act instantly. Against a
live agent, the worst a fully compromised guardian achieves is a public proposal
the agent vetoes with one proof; against a lost key it achieves exactly the
recovery it exists for. An owner-style setter would instead put a secp256k1 key
in charge of a post-quantum authority — the weakest link in a system whose
entire claim is that it does not have one.

**The agent can fire the guardian** (`rotateSetGuardian`), and that is not a
nicety. Vetoing costs a Groth16 proof; proposing costs the guardian one cheap
call, so a guardian that re-proposes after every veto would drain the agent for
almost nothing. Firing it — and killing its live proposal, in the same
transaction — is the way out of that loop. The agent is the principal and the
guardian is its delegate; a principal that cannot fire its delegate is not in
charge. This costs recovery nothing: an agent that can produce that proof is by
definition not the lost-key case the guardian exists for.

Two invariants worth stating plainly:

- **No-brick.** `agentPkCount >= 1` after every operation; revoking the last key
  reverts. (The MIP's "a configuration that cannot be satisfied can never be
  installed.")
- **Revocation is retroactive.** `pqAttested` resolves through the key that
  minted the attestation, so revoking a compromised key voids everything it ever
  signed, including already-recorded attestations. Corollary: do not revoke a
  merely-*lost* key that has unexecuted orders in flight — add the new key,
  let them settle, then revoke.

### Rotating

Statements are a fixed 137-byte binary layout built by `src/pq_rotation.py` and
recomputed on-chain by `MLDSAAttestationV2.statementBytes` — no parser on the
chain side. Domain tag, action, chain id, contract address, nonce and subject
are all inside the signed bytes, so a statement is single-use and inert on any
other chain or deployment. The two implementations are held together by parity
goldens in `contracts/test/MLDSAAttestationV2Parity.t.sol` and
`tests/test_pq_rotation.py`.

```bash
# 1. build + sign the statement with the CURRENTLY authorised key
python -m src.pq_rotation --action add \
    --subject 0x<sha256 of the NEW keys/pq.pub> \
    --contract 0x<MLDSAAttestationV2> --chain-id 143 \
    --nonce $(cast call 0x<MLDSAAttestationV2> 'rotationNonce()(uint256)' --rpc-url https://rpc.monad.xyz) \
    --keys keys/ --out zk-mldsa/mldsa_input.json

# 2. prove it — the SAME pipeline as an order, see "Finish it" above
# 3. submit rotateAdd(newPkHash, publicValues, proofBytes)
```

Nothing about the order path changes: `attest`, `isValidProof` and
`IPQAttestation.pqAttested` keep their signatures, so the executors need no
interface change — only a redeploy to repoint their immutable `PQ()`, which is
the last time that should be necessary.

**Counting honestly:** `zk-mldsa/contracts/` is a SEPARATE Foundry project, so
its 43 rotation tests (`forge test` run from that directory) are not part of the
root README's headline number, which counts `tests/` and `contracts/` only. The
Groth16 leg is not among them and cannot be — a real proof cannot be produced
inside a Foundry test. What covers it is
`script/DeployMLDSAAttestationV2.s.sol`, which calls `isValidProof` against a
real fixture on the real verifier immediately after deploying.

## Numbers for the pitch (independently citeable)

- Prior art (SP1 Dilithium verifier): ~22 s proofs, ~260-byte on-chain proof.
- This build: real ML-DSA-65 verification of the **mainnet-settled order** runs
  provably in the zkVM (3.04M cycles); the on-chain check is a Groth16 proof at
  a **measured 1 192 295 gas**. Earlier drafts of this file said ~230k, which
  was never measured — the figure above comes from the transaction receipt.
- Honest: no quantum advantage anywhere here; this is the PQ-*settlement* path,
  moving an 8.1M-gas EVM verification into a 1.2M-gas succinct proof check.
