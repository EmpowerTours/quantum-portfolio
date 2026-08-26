// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MLDSAAttestationV2} from "../src/MLDSAAttestationV2.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";

/// @notice Cross-language parity for the reconfiguration statement bytes.
///
///         The agent builds and ML-DSA-signs the statement in Python
///         (`src/pq_rotation.statement_bytes`); this contract rebuilds it in
///         Solidity and compares hashes. Two independent implementations of one
///         byte layout is exactly where a silent divergence lives, and the
///         failure mode is nasty and slow: the divergence is invisible until
///         after a Groth16 proof has been paid for and produced, at which point
///         the rotation reverts `StatementMismatch` and the proof is worthless.
///
///         The matching Python assertions are in `tests/test_pq_rotation.py`
///         (`test_statement_hash_matches_solidity_golden`), so a change to
///         either side fails one of the two suites.
///
///         If you are here because this test failed: do NOT update the golden.
///         One of the two implementations has drifted.
contract MLDSAAttestationV2ParityTest is Test {
    /// Statements are domain-separated by (chainid, address(this)), so a
    /// golden is only meaningful for a FIXED chain id and contract address.
    uint256 constant GOLDEN_CHAIN_ID = 143;
    address constant GOLDEN_ADDR = 0x00000000000000000000000000000000000000A2;

    bytes32 constant GOLDEN_ADD_NONCE0 =
        0xb81fc460ad77ceaed77fde8f091446556abc0f6c82c21aa6e949168661d05d46;
    bytes32 constant GOLDEN_REVOKE_NONCE7 =
        0xb3462d0b550aecf777ae848537299f2512a19654d4d295bd03943dd6c7e4fda6;
    /// nonce 2**64 — proves the field is a full uint256 on both sides, not the
    /// uint64 the eta field next to it happens to be.
    bytes32 constant GOLDEN_VETO_BIGNONCE =
        0x5be4f50ec4f115316046526d3a17f77eb36fc81083c7217b5751ed06cc3277f0;

    /// The guardian subject is an ADDRESS, left-padded to bytes32.
    bytes32 constant GOLDEN_SETGUARDIAN_NONCE0 =
        0x78ccbd15b81729d9dfed0156056e87f1fb9adb916b549d59cad25bc0d3a38691;
    address constant GOLDEN_GUARDIAN = 0x000000000000000000000000000000000000dEaD;

    MLDSAAttestationV2 att;

    function setUp() public {
        vm.chainId(GOLDEN_CHAIN_ID);
        MockSP1Verifier v = new MockSP1Verifier();
        deployCodeTo(
            "MLDSAAttestationV2.sol:MLDSAAttestationV2",
            abi.encode(address(v), keccak256("vkey"), keccak256("genesis-pk"),
                       address(0x60A), uint64(7 days)),
            GOLDEN_ADDR
        );
        att = MLDSAAttestationV2(GOLDEN_ADDR);
    }

    function test_statementLayoutIs137Bytes() public view {
        assertEq(att.statementBytes(1, bytes32(uint256(1)), 0).length, 137);
    }

    function test_addStatementMatchesPythonGolden() public view {
        assertEq(
            att.statementHash(1, bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111)), 0),
            GOLDEN_ADD_NONCE0
        );
    }

    function test_revokeStatementMatchesPythonGolden() public view {
        assertEq(
            att.statementHash(2, bytes32(uint256(0x2222222222222222222222222222222222222222222222222222222222222222)), 7),
            GOLDEN_REVOKE_NONCE7
        );
    }

    function test_setGuardianStatementMatchesPythonGolden() public view {
        assertEq(
            att.statementHash(4, bytes32(uint256(uint160(GOLDEN_GUARDIAN))), 0),
            GOLDEN_SETGUARDIAN_NONCE0
        );
    }

    function test_vetoStatementMatchesPythonGolden() public view {
        assertEq(
            att.statementHash(3, bytes32(uint256(0x3333333333333333333333333333333333333333333333333333333333333333)), 1 << 64),
            GOLDEN_VETO_BIGNONCE
        );
    }
}
