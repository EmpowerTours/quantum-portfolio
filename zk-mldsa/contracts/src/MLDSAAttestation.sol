// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";

/// @notice Public values committed by the SP1 ML-DSA guest.
struct PublicValuesStruct {
    bytes32 orderHash;
    bytes32 pkHash;
}

/// @title  MLDSAAttestation
/// @notice On-chain consumer of the SP1 zkVM proof that an order was signed
///         with a valid post-quantum ML-DSA-65 (FIPS 204) signature.
///
///         This closes the "Q-Day on the on-chain leg" gap: instead of the
///         ~500M-gas estimate for verifying ML-DSA directly in the EVM (which
///         exceeds Monad's 150M block gas limit, so it cannot be included at
///         all), the lattice verification runs off-chain in the zkVM and this
///         contract checks a Groth16 proof for a measured 1,196,224 gas.
///         A successful call is a permanent
///         on-chain attestation that `orderHash` carries a valid PQ signature —
///         which the AuditAnchor / vault / adapter can gate on for
///         quantum-safe settlement.
contract MLDSAAttestation {
    /// @notice SP1 verifier (a version-specific SP1Verifier or the
    ///         SP1VerifierGateway). See succinctlabs/sp1-contracts deployments.
    address public immutable verifier;

    /// @notice Verification key of the ML-DSA-65 guest program.
    bytes32 public immutable mldsaProgramVKey;

    /// @notice SHA-256 of the agent's ML-DSA-65 public key.
    ///
    ///         Without this the guest's committed statement was existentially
    ///         quantified over the signing key — "SOME keypair signed
    ///         something hashing to X" — so anyone could generate a keypair,
    ///         sign an order of their own invention, produce a valid Groth16
    ///         proof, and have this contract record it as PQ-attested. Pinning
    ///         the fingerprint makes the attestation mean what the NatSpec
    ///         below always claimed. (Audit H-3.)
    bytes32 public immutable agentPkHash;

    /// @notice orderHash => attested (a valid ML-DSA-65 signature was proven).
    mapping(bytes32 => bool) public pqAttested;

    event PQOrderAttested(bytes32 indexed orderHash);

    error UnknownSigner(bytes32 got, bytes32 expected);

    /// @dev All three arguments are immutable with no setter and no owner, so
    ///      a wrong value here is a permanent write-off — the contract must be
    ///      redeployed. Validate every one of them.
    ///
    ///      Both failures here are liveness, not safety, and it is worth being
    ///      precise about why. `verifyProof` is declared `external view`
    ///      returning nothing, so Solidity emits an `extcodesize` check before
    ///      the staticcall; against a codeless address that check reverts, and
    ///      it reverts UNCATCHABLY (a `try/catch` around the call does not
    ///      intercept it — verified empirically). So a wrong verifier bricks
    ///      `attest` rather than silently attesting an unverified proof. The
    ///      silent-pass hazard would only exist if this contract used a
    ///      low-level `.staticcall`, where success is `true` for an EOA — it
    ///      deliberately does not. A zero vkey likewise guarantees no real SP1
    ///      proof ever verifies.
    ///
    ///      Bricked is still unrecoverable, hence the requires. (Audit L-6.)
    constructor(address _verifier, bytes32 _mldsaProgramVKey, bytes32 _agentPkHash) {
        require(_agentPkHash != bytes32(0), "agentPkHash unset");
        require(_mldsaProgramVKey != bytes32(0), "mldsaProgramVKey unset");
        require(_verifier.code.length > 0, "verifier has no code");
        verifier = _verifier;
        mldsaProgramVKey = _mldsaProgramVKey;
        agentPkHash = _agentPkHash;
    }

    /// @notice Verify the SP1 proof; on success record & emit the attested
    ///         `orderHash`. Reverts if the proof is invalid.
    /// @param  _publicValues abi-encoded PublicValuesStruct (the orderHash).
    /// @param  _proofBytes   the Groth16 proof bytes from SP1.
    /// @return orderHash the PQ-attested order hash.
    function attest(bytes calldata _publicValues, bytes calldata _proofBytes)
        external
        returns (bytes32 orderHash)
    {
        ISP1Verifier(verifier).verifyProof(mldsaProgramVKey, _publicValues, _proofBytes);
        PublicValuesStruct memory pv = abi.decode(_publicValues, (PublicValuesStruct));
        if (pv.pkHash != agentPkHash) revert UnknownSigner(pv.pkHash, agentPkHash);
        orderHash = pv.orderHash;
        pqAttested[orderHash] = true;
        emit PQOrderAttested(orderHash);
    }

    /// @notice View-only proof check (does not record state). Applies the same
    ///         signer pin as `attest` — a view that accepted any signer would
    ///         be a trap for integrators reading it as "is this order valid".
    function isValidProof(bytes calldata _publicValues, bytes calldata _proofBytes)
        external
        view
        returns (bytes32 orderHash)
    {
        ISP1Verifier(verifier).verifyProof(mldsaProgramVKey, _publicValues, _proofBytes);
        PublicValuesStruct memory pv = abi.decode(_publicValues, (PublicValuesStruct));
        if (pv.pkHash != agentPkHash) revert UnknownSigner(pv.pkHash, agentPkHash);
        return pv.orderHash;
    }
}
