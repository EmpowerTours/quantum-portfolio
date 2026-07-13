use alloy_sol_types::sol;
use ml_dsa::signature::Verifier;
use ml_dsa::{EncodedSignature, EncodedVerifyingKey, MlDsa65, Signature, VerifyingKey};
use sha2::{Digest, Sha256};

sol! {
    /// Public values committed by the guest and checkable on-chain.
    /// A valid proof asserts: "a valid ML-DSA-65 (FIPS 204) signature exists
    /// over a message whose SHA-256 is `orderHash`." The on-chain contract can
    /// then trust that the agent's PQ-signed order `orderHash` is authentic,
    /// without the ~500M-gas cost of verifying ML-DSA inside the EVM.
    struct PublicValuesStruct {
        bytes32 orderHash;
    }
}

/// Verify a pure ML-DSA-65 (empty context) signature over `msg` and, if valid,
/// return SHA-256(msg) — the canonical order hash used across the pipeline and
/// the on-chain AuditAnchor. Returns `None` if the signature is invalid or the
/// key/signature bytes are malformed.
pub fn verify_and_digest(pk: &[u8], msg: &[u8], sig: &[u8]) -> Option<[u8; 32]> {
    let enc_vk = EncodedVerifyingKey::<MlDsa65>::try_from(pk).ok()?;
    let vk = VerifyingKey::<MlDsa65>::decode(&enc_vk);

    let enc_sig = EncodedSignature::<MlDsa65>::try_from(sig).ok()?;
    let signature = Signature::<MlDsa65>::decode(&enc_sig)?;

    vk.verify(msg, &signature).ok()?;

    let digest = Sha256::digest(msg);
    let mut out = [0u8; 32];
    out.copy_from_slice(&digest);
    Some(out)
}
