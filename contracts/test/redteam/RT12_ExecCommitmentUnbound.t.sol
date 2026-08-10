// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MockPQAttestation } from "../mocks/MockPQAttestation.sol";
import { PQBind }             from "../helpers/PQBind.sol";
import { PQExecBinding }      from "../../src/PQExecBinding.sol";
import { WMON }               from "../../src/dex/WMON.sol";
import { MockToken }          from "../../src/dex/MockToken.sol";
import { AuditAnchorV2 }      from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { FaithfulRouter }     from "./RT03_DustInvariantAttacks.t.sol";

/// @title  RT12 — execution is bound to the signed order
///
/// @notice HISTORY. These tests once PASSED while ASSERTING THE ATTACK
///         SUCCEEDED. The ZK guest commits only `(orderHash, pkHash)`, so the
///         attestation proved "the pinned key signed some order hashing to X"
///         and nothing about what X authorised. `execCommitment` was chosen by
///         whoever called `anchor()`, and `AlreadyAnchored` is keyed
///         per-caller — so any address, including the agent's own ECDSA key,
///         could bind an arbitrary execution to an attested orderHash and
///         execute it, leaving an on-chain record that passed every check
///         while describing a trade the signature never authorised.
///
///         Schema v3 puts `exec_commitment` inside the signed bytes and
///         `PQExecBinding` checks it against the executor's own calldata. The
///         assertions below are now INVERTED: every path that used to succeed
///         must revert. If any of them stops reverting, the binding has been
///         lost again.
contract RT12_ExecCommitmentUnbound is Test {
    WMON wmon;
    MockToken usdc;
    MockToken usdt;
    AuditAnchorV2 anchor;
    FaithfulRouter router;
    UniswapRoutingVault vault;
    MockPQAttestation pq;

    address agent    = address(0xA6E17);
    address attacker = address(0xBAD);

    uint24 constant FEE = 3000;
    uint256 constant FUTURE = 1e18;

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("USDC", "USDC", 18);
        usdt = new MockToken("USDT", "USDT", 18);
        anchor = new AuditAnchorV2();
        router = new FaithfulRouter();
        pq = new MockPQAttestation();
        pq.setAttestAll(false);

        address[] memory toks = new address[](2);
        toks[0] = address(usdc);
        toks[1] = address(usdt);
        uint24[] memory fees = new uint24[](1);
        fees[0] = FEE;
        vault = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), address(pq), toks, fees
        );

        // MockToken caps a single faucet call, so loop — a single
        // faucet(1_000_000 ether) reverts AmountTooLarge and would take the
        // whole setUp with it, silently preventing every test in this file
        // from running at all.
        for (uint256 i = 0; i < 10; ++i) {
            usdc.faucet(100_000 ether);
            usdt.faucet(100_000 ether);
        }
        usdc.transfer(address(router), 1_000_000 ether);
        usdt.transfer(address(router), 1_000_000 ether);
        vm.deal(agent, 100 ether);
        vm.deal(attacker, 100 ether);
    }

    function _legs(address out)
        internal
        pure
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](1); t[0] = out;
        f = new uint24[](1);  f[0] = FEE;
        w = new uint16[](1);  w[0] = 10_000;
        m = new uint256[](1); m[0] = 1;
    }

    /// Build the preimage the SIGNER would have produced for these parameters.
    function _signed(address who, address[] memory t, uint24[] memory f,
                     uint16[] memory w, uint256 val, uint256[] memory m)
        internal view returns (bytes32 h, bytes memory pre)
    {
        bytes32 paramsHash = keccak256(
            abi.encode(block.chainid, address(vault), who, t, f, w, val, m, FUTURE)
        );
        (pre, h) = PQBind.preimage(paramsHash);
    }

    /// WAS: a third party bound a completely different trade to the agent's
    /// attested orderHash and executed it. NOW: the preimage that hashes to
    /// that orderHash commits to the agent's parameters, so the attacker's
    /// divergent execution cannot satisfy the binding.
    function test_RivalAnchorOnAnAttestedOrderHashNowReverts() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(address(usdc));
        m[0] = 1900 ether;                       // the signed slippage floor
        (bytes32 H, bytes memory pre) = _signed(agent, t, f, w, 1 ether, m);
        pq.setAttested(H, true);

        // Hoisted: vm.prank applies to the NEXT external call, and an
        // argument is evaluated first — inline, routeCommitment ate the
        // prank and anchor() came from the test contract instead.
        bytes32 c_agent = vault.routeCommitment(H, agent, t, f, w, 1 ether, m, FUTURE);
        vm.prank(agent);
        anchor.anchor(H, c_agent, 0);

        // The attacker still CAN anchor — anchoring is permissionless and the
        // map is keyed per caller. That was never the defect on its own.
        (address[] memory t2, uint24[] memory f2, uint16[] memory w2, uint256[] memory m2) =
            _legs(address(usdt));
        m2[0] = 1;
        // Hoisted: vm.prank applies to the NEXT external call, and an
        // argument is evaluated first — inline, routeCommitment ate the
        // prank and anchor() came from the test contract instead.
        bytes32 c_attacker = vault.routeCommitment(H, attacker, t2, f2, w2, 50 ether, m2, FUTURE);
        vm.prank(attacker);
        anchor.anchor(H, c_attacker, 0);

        // ...but executing it cannot pass the binding: the signed preimage
        // commits to the agent's parameters, not the attacker's.
        vm.prank(attacker);
        vm.expectRevert();
        vault.executeAndRoute{ value: 50 ether }(H, t2, f2, w2, m2, FUTURE, pre);

        assertFalse(vault.consumed(attacker, H), "attacker must not execute");
        assertEq(usdt.balanceOf(attacker), 0,    "no trade the order never described");

        // The agent's own legitimate execution still works.
        vm.prank(agent);
        vault.executeAndRoute{ value: 1 ether }(H, t, f, w, m, FUTURE, pre);
        assertTrue(vault.consumed(agent, H), "the signed execution must still succeed");
    }

    /// The sharper one. WAS: the agent's own ECDSA key could anchor and execute
    /// a trade contradicting the PQ-signed intent, defeating the two-key
    /// custody property. NOW: the ECDSA key cannot alter what the PQ key
    /// signed without breaking sha256(preimage) == orderHash.
    function test_AgentsOwnEcdsaKeyCanNoLongerDivergeFromPqSignedIntent() public {
        // PQ-signed intent: USDC with a real floor.
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(address(usdc));
        m[0] = 1900 ether;
        (bytes32 H, bytes memory pre) = _signed(agent, t, f, w, 1 ether, m);
        pq.setAttested(H, true);

        // The ECDSA key tries USDT with the floor gutted.
        (address[] memory t2, uint24[] memory f2, uint16[] memory w2, uint256[] memory m2) =
            _legs(address(usdt));
        m2[0] = 1;
        // Hoisted: vm.prank applies to the NEXT external call, and an
        // argument is evaluated first — inline, routeCommitment ate the
        // prank and anchor() came from the test contract instead.
        bytes32 c_agent = vault.routeCommitment(H, agent, t2, f2, w2, 1 ether, m2, FUTURE);
        vm.prank(agent);
        anchor.anchor(H, c_agent, 0);

        vm.prank(agent);
        vm.expectRevert();
        vault.executeAndRoute{ value: 1 ether }(H, t2, f2, w2, m2, FUTURE, pre);

        assertFalse(vault.consumed(agent, H), "divergent execution must not settle");
    }

    /// A preimage that does not hash to the attested orderHash is rejected
    /// outright — the binding cannot be satisfied by supplying different bytes.
    function test_ForeignPreimageIsRejected() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(address(usdc));
        (bytes32 H, ) = _signed(agent, t, f, w, 1 ether, m);
        pq.setAttested(H, true);
        // Hoisted: vm.prank applies to the NEXT external call, and an
        // argument is evaluated first — inline, routeCommitment ate the
        // prank and anchor() came from the test contract instead.
        bytes32 c_agent = vault.routeCommitment(H, agent, t, f, w, 1 ether, m, FUTURE);
        vm.prank(agent);
        anchor.anchor(H, c_agent, 0);

        (, bytes memory otherPre) = _signed(attacker, t, f, w, 99 ether, m);

        vm.prank(agent);
        vm.expectRevert();
        vault.executeAndRoute{ value: 1 ether }(H, t, f, w, m, FUTURE, otherPre);
    }

    /// CONTROL: the pre-existing anchor==params check still fires, so the new
    /// binding is an addition rather than a replacement.
    function test_Control_VaultStillRejectsUnanchoredParams() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(address(usdc));
        (bytes32 H, bytes memory pre) = _signed(agent, t, f, w, 1 ether, m);
        pq.setAttested(H, true);
        // Hoisted: vm.prank applies to the NEXT external call, and an
        // argument is evaluated first — inline, routeCommitment ate the
        // prank and anchor() came from the test contract instead.
        bytes32 c_agent = vault.routeCommitment(H, agent, t, f, w, 1 ether, m, FUTURE);
        vm.prank(agent);
        anchor.anchor(H, c_agent, 0);

        m[0] = 12345;                            // deviate at execution time
        vm.prank(agent);
        vm.expectRevert();
        vault.executeAndRoute{ value: 1 ether }(H, t, f, w, m, FUTURE, pre);
    }
}
