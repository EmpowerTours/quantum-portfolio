// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { AuditAnchorV2 } from "../src/AuditAnchorV2.sol";

/// @notice Direct tests for AuditAnchorV2.
///
/// @dev    This file exists because it did not. A mutation sweep found that
///         `SequenceMismatch` and `ZeroCommitment` could BOTH be deleted from
///         `anchor()` with all 135 tests still passing — the V2 anchor was
///         only ever exercised indirectly, as setup for vault and adapter
///         tests, and `test/AuditAnchor.t.sol` imports the superseded V1.
///
///         Every negative assertion below names the exact selector. A bare
///         `vm.expectRevert()` would pass for the wrong reason and is what
///         let these guards look covered.
contract AuditAnchorV2Test is Test {
    AuditAnchorV2 anchor;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    bytes32 constant OH  = keccak256("order-1");
    bytes32 constant OH2 = keccak256("order-2");
    bytes32 constant C   = keccak256("commitment-1");
    bytes32 constant C2  = keccak256("commitment-2");

    event Anchored(
        address indexed anchorer,
        bytes32 indexed orderHash,
        uint64  indexed sequence,
        bytes32 prevHash,
        bytes32 execCommitment
    );

    function setUp() public {
        anchor = new AuditAnchorV2();
    }

    // --- the two guards that survived mutation --------------------------

    /// A caller whose belief about the counter is stale must be rejected, so a
    /// duplicated or reordered relay cannot land silently.
    function test_RevertsOnSequenceMismatch() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AuditAnchorV2.SequenceMismatch.selector, uint64(0), uint64(7))
        );
        anchor.anchor(OH, C, 7);
    }

    /// After one successful anchor the expected sequence moves; re-submitting
    /// the OLD expectation must fail rather than quietly succeed.
    function test_RevertsWhenReplayingAStaleSequence() public {
        vm.prank(alice);
        anchor.anchor(OH, C, 0);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AuditAnchorV2.SequenceMismatch.selector, uint64(1), uint64(0))
        );
        anchor.anchor(OH2, C2, 0);
    }

    /// A zero commitment would be indistinguishable from "never anchored",
    /// because that is exactly how `execCommitmentOf` encodes absence. An
    /// executor reading it back would see bytes32(0) and revert AnchorNotFound
    /// on an order the anchor believes it recorded — a burnt sequence number
    /// and a permanently unusable orderHash.
    function test_RevertsOnZeroCommitment() public {
        vm.prank(alice);
        vm.expectRevert(AuditAnchorV2.ZeroCommitment.selector);
        anchor.anchor(OH, bytes32(0), 0);
    }

    function test_ZeroCommitmentDoesNotConsumeASequenceNumber() public {
        vm.prank(alice);
        vm.expectRevert(AuditAnchorV2.ZeroCommitment.selector);
        anchor.anchor(OH, bytes32(0), 0);

        assertEq(anchor.nextSequence(alice), 0, "a rejected anchor must not advance the counter");
        vm.prank(alice);
        anchor.anchor(OH, C, 0);
        assertEq(anchor.nextSequence(alice), 1);
    }

    // --- the remaining guards -------------------------------------------

    function test_RevertsOnZeroHash() public {
        vm.prank(alice);
        vm.expectRevert(AuditAnchorV2.ZeroHash.selector);
        anchor.anchor(bytes32(0), C, 0);
    }

    /// An anchor is permanent evidence. Re-anchoring the same orderHash with a
    /// DIFFERENT commitment would let a caller redirect an already-published
    /// order — the exact hole M-6 closed.
    function test_RevertsOnReAnchoringTheSameOrderHash() public {
        vm.prank(alice);
        anchor.anchor(OH, C, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AuditAnchorV2.AlreadyAnchored.selector, OH));
        anchor.anchor(OH, C2, 1);

        assertEq(anchor.execCommitmentOf(alice, OH), C, "the original commitment must survive");
    }

    /// Re-anchoring with the IDENTICAL commitment must also fail: permanence is
    /// the property, not idempotence.
    function test_RevertsOnReAnchoringEvenWithTheSameCommitment() public {
        vm.prank(alice);
        anchor.anchor(OH, C, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AuditAnchorV2.AlreadyAnchored.selector, OH));
        anchor.anchor(OH, C, 1);
    }

    // --- per-anchorer isolation -----------------------------------------

    /// Commitments are keyed by (anchorer, orderHash). Bob anchoring must not
    /// grant Alice anything, and must not disturb her counter.
    function test_CommitmentsAreIsolatedPerAnchorer() public {
        vm.prank(alice);
        anchor.anchor(OH, C, 0);

        vm.prank(bob);
        anchor.anchor(OH, C2, 0);   // same orderHash, different anchorer: allowed

        assertEq(anchor.execCommitmentOf(alice, OH), C);
        assertEq(anchor.execCommitmentOf(bob,   OH), C2);
        assertEq(anchor.nextSequence(alice), 1);
        assertEq(anchor.nextSequence(bob),   1);
    }

    function test_UnanchoredPairReadsAsZero() public view {
        assertEq(anchor.execCommitmentOf(alice, OH), bytes32(0));
        assertEq(anchor.nextSequence(alice), 0);
    }

    // --- the audit-trail leg --------------------------------------------

    /// `lastHash` is documented as NOT an authorisation source. Assert the
    /// documented behaviour so a future reader cannot mistake it for a gate:
    /// it tracks the most recent orderHash and nothing reads it to authorise.
    function test_LastHashTracksMostRecentAndIsNotAuthorisation() public {
        assertEq(anchor.lastHash(alice), bytes32(0));

        vm.prank(alice);
        anchor.anchor(OH, C, 0);
        assertEq(anchor.lastHash(alice), OH);

        vm.prank(alice);
        anchor.anchor(OH2, C2, 1);
        assertEq(anchor.lastHash(alice), OH2, "lastHash follows the newest anchor");

        // The older order is still independently authorised — which is the
        // whole difference from V1, where only the newest hash was usable.
        assertEq(anchor.execCommitmentOf(alice, OH), C,
            "an earlier order must remain authorised after a later one is anchored");
    }

    function test_EmitsAnchoredWithPreviousHash() public {
        vm.prank(alice);
        anchor.anchor(OH, C, 0);

        vm.expectEmit(true, true, true, true);
        emit Anchored(alice, OH2, 1, OH, C2);
        vm.prank(alice);
        anchor.anchor(OH2, C2, 1);
    }

    function test_ReturnsTheAssignedSequence() public {
        vm.prank(alice);
        assertEq(anchor.anchor(OH, C, 0), 0);
        vm.prank(alice);
        assertEq(anchor.anchor(OH2, C2, 1), 1);
    }

    // --- fuzz -------------------------------------------------------------

    function testFuzz_AnyNonZeroExpectationOtherThanTheCounterReverts(uint64 wrong) public {
        vm.assume(wrong != 0);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AuditAnchorV2.SequenceMismatch.selector, uint64(0), wrong)
        );
        anchor.anchor(OH, C, wrong);
    }

    function testFuzz_SequenceIsMonotonicPerAnchorer(uint8 n) public {
        n = uint8(bound(n, 1, 30));
        for (uint64 i = 0; i < n; ++i) {
            vm.prank(alice);
            uint64 got = anchor.anchor(keccak256(abi.encode("o", i)), keccak256(abi.encode("c", i)), i);
            assertEq(got, i, "sequence must equal the number of prior anchors");
        }
        assertEq(anchor.nextSequence(alice), n);
        assertEq(anchor.nextSequence(bob), 0, "bob's counter is untouched");
    }
}
