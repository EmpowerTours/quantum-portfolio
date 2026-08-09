// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  IPQAttestation
/// @notice The single fact an executor needs from the attestation layer: has a
///         post-quantum (ML-DSA-65) signature over this orderHash been verified
///         on-chain?
/// @dev    Deliberately one function. The executors must not depend on how the
///         proof is produced — SP1 + Groth16 today, something else after
///         FIPS 206 — only on whether verification happened. Implemented by
///         `zk-mldsa/contracts/src/MLDSAAttestation.sol`.
interface IPQAttestation {
    /// @return true once `attest()` has verified a proof for this orderHash.
    function pqAttested(bytes32 orderHash) external view returns (bool);
}
