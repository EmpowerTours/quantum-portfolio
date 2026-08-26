// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";

/// @notice Test double for the SP1 Groth16 verifier.
/// @dev    A real Groth16 proof cannot be produced inside a Foundry test, so
///         the suite drives the verifier's VERDICT directly and tests the layer
///         that actually changed in V2: which key is authorised, what it signed
///         and when. The Groth16 leg is covered where it can be — by
///         `DeployMLDSAAttestationV2.s.sol`, which calls `isValidProof` against
///         a real fixture on the real verifier immediately after broadcasting.
contract MockSP1Verifier is ISP1Verifier {
    bool public accept = true;
    error ProofRejected();

    function setAccept(bool v) external { accept = v; }

    function verifyProof(bytes32, bytes calldata, bytes calldata) external view {
        if (!accept) revert ProofRejected();
    }
}
