//! SP1 guest: verify an ML-DSA-65 (FIPS 204) signature over the agent's
//! canonical order bytes, and commit SHA-256(order) as the public output.
//!
//! A valid proof of this program is a succinct, EVM-cheap attestation that a
//! valid post-quantum ML-DSA-65 signature exists over an order whose hash is
//! the committed `orderHash` — the same hash anchored on-chain by AuditAnchor.
//! This is the buildable path to on-chain PQ settlement: the ~500M-gas EVM
//! ML-DSA verification is moved off-chain into the zkVM and replaced by a
//! ~230k-gas Groth16 proof check.

#![no_main]
sp1_zkvm::entrypoint!(main);

use alloy_sol_types::SolType;
use fibonacci_lib::{verify_and_digest, PublicValuesStruct};

pub fn main() {
    // Read the ML-DSA-65 public key, the signed message (canonical order
    // bytes), and the signature.
    let pk = sp1_zkvm::io::read::<Vec<u8>>();
    let msg = sp1_zkvm::io::read::<Vec<u8>>();
    let sig = sp1_zkvm::io::read::<Vec<u8>>();

    // Verify inside the zkVM. If the signature is invalid the guest panics, so
    // a proof can only exist for a genuinely valid signature.
    let order_hash = verify_and_digest(&pk, &msg, &sig)
        .expect("ML-DSA-65 verification failed");

    // Commit SHA-256(order) as the public value.
    let bytes = PublicValuesStruct::abi_encode(&PublicValuesStruct {
        orderHash: order_hash.into(),
    });
    sp1_zkvm::io::commit_slice(&bytes);
}
