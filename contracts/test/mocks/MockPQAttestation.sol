// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPQAttestation } from "../../src/IPQAttestation.sol";

/// @notice Test double for the attestation registry.
/// @dev    The real one (`MLDSAAttestation`) only sets `pqAttested` after
///         verifying a Groth16 proof of an ML-DSA-65 signature, which cannot be
///         produced inside a Foundry test. Tests therefore drive the FLAG
///         directly. `attestAll` exists so the large pre-existing suites, which
///         are about routing and dust and provenance rather than about the PQ
///         gate, do not each have to attest every hash they invent.
contract MockPQAttestation is IPQAttestation {
    mapping(bytes32 => bool) private _attested;

    /// @dev Defaults to TRUE. The pre-existing suites are about routing, dust,
    ///      weights and provenance — not about the PQ gate — and would all fail
    ///      closed for a reason unrelated to what they assert. Tests that
    ///      exercise the gate itself set this false explicitly. See
    ///      PQAttestationGate.t.sol.
    bool public attestAll = true;

    function pqAttested(bytes32 orderHash) external view returns (bool) {
        return attestAll || _attested[orderHash];
    }

    function setAttested(bytes32 orderHash, bool v) external { _attested[orderHash] = v; }
    function setAttestAll(bool v) external { attestAll = v; }
}
