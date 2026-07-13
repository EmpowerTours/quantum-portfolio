// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";

/// @notice Public values committed by the SP1 ML-DSA guest.
struct PublicValuesStruct {
    bytes32 orderHash;
}

/// @title  MLDSAAttestation
/// @notice On-chain consumer of the SP1 zkVM proof that an order was signed
///         with a valid post-quantum ML-DSA-65 (FIPS 204) signature.
///
///         This closes the "Q-Day on the on-chain leg" gap: instead of the
///         ~500M-gas cost of verifying ML-DSA directly in the EVM (infeasible),
///         the lattice verification runs off-chain in the zkVM and this contract
///         checks a ~230k-gas Groth16 proof. A successful call is a permanent
///         on-chain attestation that `orderHash` carries a valid PQ signature —
///         which the AuditAnchor / vault / adapter can gate on for
///         quantum-safe settlement.
contract MLDSAAttestation {
    /// @notice SP1 verifier (a version-specific SP1Verifier or the
    ///         SP1VerifierGateway). See succinctlabs/sp1-contracts deployments.
    address public immutable verifier;

    /// @notice Verification key of the ML-DSA-65 guest program.
    bytes32 public immutable mldsaProgramVKey;

    /// @notice orderHash => attested (a valid ML-DSA-65 signature was proven).
    mapping(bytes32 => bool) public pqAttested;

    event PQOrderAttested(bytes32 indexed orderHash);

    constructor(address _verifier, bytes32 _mldsaProgramVKey) {
        verifier = _verifier;
        mldsaProgramVKey = _mldsaProgramVKey;
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
        orderHash = pv.orderHash;
        pqAttested[orderHash] = true;
        emit PQOrderAttested(orderHash);
    }

    /// @notice View-only proof check (does not record state).
    function isValidProof(bytes calldata _publicValues, bytes calldata _proofBytes)
        external
        view
        returns (bytes32 orderHash)
    {
        ISP1Verifier(verifier).verifyProof(mldsaProgramVKey, _publicValues, _proofBytes);
        return abi.decode(_publicValues, (PublicValuesStruct)).orderHash;
    }
}
