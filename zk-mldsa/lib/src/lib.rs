use alloy_sol_types::sol;
use ml_dsa::signature::Verifier;
use ml_dsa::{EncodedSignature, EncodedVerifyingKey, MlDsa65, Signature, VerifyingKey};
use sha2::{Digest, Sha256};

sol! {
    /// Public values committed by the guest and checkable on-chain.
    ///
    /// A valid proof asserts: "the ML-DSA-65 (FIPS 204) key whose SHA-256 is
    /// `pkHash` produced a valid signature over a message whose SHA-256 is
    /// `orderHash`."
    ///
    /// `pkHash` is load-bearing. Committing only `orderHash` made the
    /// statement existentially quantified over the key — "SOME keypair signed
    /// something hashing to X" — so anyone could generate their own ML-DSA
    /// keypair, sign an order they invented, produce a valid Groth16 proof and
    /// mint an attestation for an arbitrary order hash. The proof attested
    /// that a signature existed, never that the AGENT authorised the order.
    /// MLDSAAttestation pins `pkHash` against an immutable expected value, so
    /// the attestation now means what its NatSpec always claimed. (Audit H-3.)
    struct PublicValuesStruct {
        bytes32 orderHash;
        bytes32 pkHash;
    }
}

/// Verify a pure ML-DSA-65 (empty context) signature over `msg` and, if valid,
/// return `(SHA-256(msg), SHA-256(pk))` — the canonical order hash used across
/// the pipeline, plus the fingerprint of the key that actually signed it.
/// Returns `None` if the signature is invalid or the key/signature bytes are
/// malformed.
///
/// The key fingerprint is returned rather than discarded so the guest can
/// commit it: without it a proof says nothing about WHO signed. (Audit H-3.)
pub fn verify_and_digest(pk: &[u8], msg: &[u8], sig: &[u8]) -> Option<([u8; 32], [u8; 32])> {
    let enc_vk = EncodedVerifyingKey::<MlDsa65>::try_from(pk).ok()?;
    let vk = VerifyingKey::<MlDsa65>::decode(&enc_vk);

    let enc_sig = EncodedSignature::<MlDsa65>::try_from(sig).ok()?;
    let signature = Signature::<MlDsa65>::decode(&enc_sig)?;

    vk.verify(msg, &signature).ok()?;

    let digest = Sha256::digest(msg);
    let mut order_hash = [0u8; 32];
    order_hash.copy_from_slice(&digest);

    // Fingerprint the ENCODED key, so the committed value is a function of the
    // exact bytes that were verified against.
    let pk_digest = Sha256::digest(pk);
    let mut pk_hash = [0u8; 32];
    pk_hash.copy_from_slice(&pk_digest);

    Some((order_hash, pk_hash))
}
