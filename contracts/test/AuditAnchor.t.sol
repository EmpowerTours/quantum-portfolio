// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { AuditAnchor } from "../src/AuditAnchor.sol";

contract AuditAnchorTest is Test {
    AuditAnchor anchorContract;

    address alice = address(0xAAAA);
    address bob   = address(0xBBBB);

    bytes32 constant H1 = bytes32(uint256(0xC0FFEE01));
    bytes32 constant H2 = bytes32(uint256(0xC0FFEE02));
    bytes32 constant H3 = bytes32(uint256(0xC0FFEE03));

    function setUp() public {
        anchorContract = new AuditAnchor();
    }

    /// First anchor from a fresh address: sequence=0, prevHash=0.
    function test_FirstAnchorEmitsGenesisPrev() public {
        vm.recordLogs();
        vm.prank(alice);
        uint64 seq = anchorContract.anchor(H1, 0);
        assertEq(seq, 0);

        // Event field check
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("Anchored(address,bytes32,uint64,bytes32)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), alice);
        assertEq(logs[0].topics[2], H1);
        assertEq(uint64(uint256(logs[0].topics[3])), 0);
        assertEq(abi.decode(logs[0].data, (bytes32)), bytes32(0));

        // State check
        assertEq(anchorContract.nextSequence(alice), 1);
        assertEq(anchorContract.lastHash(alice), H1);
    }

    /// Second anchor: sequence=1, prevHash=H1, links the chain.
    function test_SecondAnchorLinksToFirst() public {
        vm.prank(alice);
        anchorContract.anchor(H1, 0);

        vm.recordLogs();
        vm.prank(alice);
        uint64 seq = anchorContract.anchor(H2, 1);
        assertEq(seq, 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint64(uint256(logs[0].topics[3])), 1);
        // prevHash in event data == H1
        assertEq(abi.decode(logs[0].data, (bytes32)), H1);
        assertEq(anchorContract.nextSequence(alice), 2);
        assertEq(anchorContract.lastHash(alice), H2);
    }

    /// Per-anchorer counters are independent: alice and bob each start at 0.
    function test_PerAnchorerSequenceIsolation() public {
        vm.prank(alice);
        anchorContract.anchor(H1, 0);
        vm.prank(bob);
        anchorContract.anchor(H2, 0);

        assertEq(anchorContract.nextSequence(alice), 1);
        assertEq(anchorContract.nextSequence(bob), 1);
        assertEq(anchorContract.lastHash(alice), H1);
        assertEq(anchorContract.lastHash(bob), H2);
    }

    /// Explicit-sequence form reverts with a typed error on mismatch.
    function test_RevertsOnSequenceMismatch() public {
        vm.prank(alice);
        anchorContract.anchor(H1, 0);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AuditAnchor.SequenceMismatch.selector, 1, 5)
        );
        anchorContract.anchor(H2, 5);
    }

    /// Zero-hash inputs are rejected — a real SHA-256 of a non-empty payload
    /// is overwhelmingly unlikely to be all zeros and accepting them would
    /// silently anchor "no payload".
    function test_RevertsOnZeroHash() public {
        vm.prank(alice);
        vm.expectRevert(AuditAnchor.ZeroHash.selector);
        anchorContract.anchor(bytes32(0), 0);

        vm.prank(alice);
        vm.expectRevert(AuditAnchor.ZeroHash.selector);
        anchorContract.anchor(bytes32(0));
    }

    /// Convenience overload (no expectedSequence) still emits coherent events.
    function test_OverloadWithoutExpectedSequenceAlsoAnchors() public {
        vm.recordLogs();
        vm.prank(alice);
        uint64 seq = anchorContract.anchor(H1);
        assertEq(seq, 0);

        vm.prank(alice);
        seq = anchorContract.anchor(H2);
        assertEq(seq, 1);

        assertEq(anchorContract.lastHash(alice), H2);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[1].topics[2], H2);
        assertEq(uint64(uint256(logs[1].topics[3])), 1);
        assertEq(abi.decode(logs[1].data, (bytes32)), H1);
    }

    /// Gas snapshot — keep us honest about the ~30 K gas target documented
    /// in SUBMISSION.md. Fails CI if anchoring ever drifts above 60 K.
    function test_GasUnderBudget() public {
        vm.prank(alice);
        uint256 g0 = gasleft();
        anchorContract.anchor(H1, 0);
        uint256 used = g0 - gasleft();
        // First anchor pays the cold-SSTORE penalty for sequence & lastHash —
        // higher than steady-state. Second anchor is the production cost.
        assertLt(used, 100_000, "first anchor over 100K gas");

        vm.prank(alice);
        g0 = gasleft();
        anchorContract.anchor(H2, 1);
        used = g0 - gasleft();
        assertLt(used, 60_000, "steady-state anchor over 60K gas - narrative says ~30K");
        emit log_named_uint("steady-state anchor gas", used);
    }

    /// Fuzz: arbitrary non-zero hashes always succeed, monotonic counter
    /// stays consistent, lastHash always reflects the last call.
    function testFuzz_AnchorRoundTrip(bytes32 h1, bytes32 h2) public {
        vm.assume(h1 != bytes32(0));
        vm.assume(h2 != bytes32(0));
        vm.prank(alice);
        anchorContract.anchor(h1, 0);
        vm.prank(alice);
        anchorContract.anchor(h2, 1);
        assertEq(anchorContract.nextSequence(alice), 2);
        assertEq(anchorContract.lastHash(alice), h2);
    }
}

