// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MockPQAttestation } from "../mocks/MockPQAttestation.sol";
import { WMON }                from "../../src/dex/WMON.sol";
import { MockToken }           from "../../src/dex/MockToken.sol";
import { AuditAnchorV2 }       from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { FaithfulRouter }      from "./RT03_DustInvariantAttacks.t.sol";

/// @title  RT12 — the execution commitment is NOT bound on-chain to the signed order
///
/// @notice READ THIS BEFORE TRUSTING A GREEN RUN. These tests PASS, and a pass
///         here means the WEAKNESS IS PRESENT. They are not asserting a
///         security property; they are pinning a known, disclosed limitation so
///         it cannot be quietly lost.
///
///         The ZK guest (zk-mldsa/program/src/main.rs) commits only
///         (orderHash, pkHash). `execCommitment` is chosen by whoever calls
///         `AuditAnchorV2.anchor()`, and `AlreadyAnchored` is keyed per-caller,
///         so any address — INCLUDING the agent's own ECDSA key — can bind an
///         arbitrary execution to an already-attested orderHash and execute it.
///         The result is an on-chain record that passes every check while
///         describing a trade the post-quantum signature never authorised.
///
///         Not theft: the caller funds `msg.value` and the router pays out to
///         `msg.sender`. The damage is provenance forgery, in a system whose
///         product is the audit trail.
///
///         It also defeats the two-key custody property asserted in
///         UniswapRoutingVault's own NatSpec — under the threat model that
///         contract declares (ECDSA compromised, PQ key not), the guarantee
///         does not hold.
///
///         WHEN THE FIX LANDS these assertions must be INVERTED: the attacker
///         path must revert. A green RT12 after the fix means the fix did not
///         work. See SUBMISSION.md, "the execution commitment is not bound
///         on-chain".
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
        // Only orders that really carry an ML-DSA proof are attested.
        pq.setAttestAll(false);

        address[] memory approved = new address[](2);
        approved[0] = address(usdc);
        approved[1] = address(usdt);
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = FEE;
        vault = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), address(pq), approved, tiers
        );

        for (uint256 i = 0; i < 5; ++i) {
            usdc.faucet(100_000 ether);
            usdt.faucet(100_000 ether);
        }
        usdc.transfer(address(router), 200_000 ether);
        usdt.transfer(address(router), 200_000 ether);

        vm.deal(agent, 1_000 ether);
        vm.deal(attacker, 1_000 ether);
    }

    function _legs(address tok)
        internal
        pure
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](1); t[0] = tok;
        f = new uint24[](1);  f[0] = FEE;
        w = new uint16[](1);  w[0] = 10_000;
        m = new uint256[](1); m[0] = 1;
    }

    /// The PQ-signed order says: route 1 MON into USDC with a real floor.
    /// Its SHA-256 is `H`. That is ALL the chain ever learns about it.
    /// Question: can a party who never saw the order pick their own execution?
    function test_PoC_AnyoneCanBindArbitraryExecutionToAnAttestedOrderHash() public {
        bytes32 H = keccak256("the-agents-PQ-signed-order");
        pq.setAttested(H, true);   // a real ML-DSA proof was verified for H

        // --- What the order actually authorised (agent's own binding) ------
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(address(usdc));
        m[0] = 1900 ether;                       // the signed slippage floor
        bytes32 honest = vault.routeCommitment(H, agent, t, f, w, 1 ether, m, FUTURE);
        vm.prank(agent);
        anchor.anchor(H, honest, 0);

        // --- The attacker: never saw the order preimage, only the hash -----
        // Picks a COMPLETELY different trade: different token, 50x the size,
        // and a gutted slippage floor.
        (address[] memory t2, uint24[] memory f2, uint16[] memory w2, uint256[] memory m2) =
            _legs(address(usdt));
        m2[0] = 1;                               // no real floor at all
        bytes32 forged = vault.routeCommitment(H, attacker, t2, f2, w2, 50 ether, m2, FUTURE);

        // AlreadyAnchored does NOT fire: the map is keyed per (msg.sender, hash).
        vm.prank(attacker);
        anchor.anchor(H, forged, 0);

        assertEq(anchor.execCommitmentOf(agent, H),    honest, "agent's binding");
        assertEq(anchor.execCommitmentOf(attacker, H), forged, "attacker's rival binding");

        // ...and it EXECUTES. Same attested orderHash, entirely different trade.
        vm.prank(attacker);
        vault.executeAndRoute{ value: 50 ether }(H, t2, f2, w2, m2, FUTURE);

        assertTrue(vault.consumed(attacker, H), "attacker executed against the agent's order");
        assertGt(usdt.balanceOf(attacker), 0,   "a trade the signed order never described");

        // The agent's own legitimate execution is unaffected — so this is not a
        // denial of service; both now sit in the log under one attested hash.
        vm.prank(agent);
        vault.executeAndRoute{ value: 1 ether }(H, t, f, w, m, FUTURE);
        assertTrue(vault.consumed(agent, H));
    }

    /// Narrower and more damaging: the AGENT'S OWN ECDSA key can anchor a
    /// commitment that diverges from the PQ-signed intent. The two-key custody
    /// claim says the PQ key authorises intent and ECDSA only executes.
    function test_PoC_AgentsOwnEcdsaKeyCanDivergeFromPqSignedIntent() public {
        bytes32 H = keccak256("intent-floor-1900-usdc");
        pq.setAttested(H, true);

        // PQ-signed intent: USDC, floor 1900. The ECDSA key instead anchors
        // USDT with floor 1 — and nothing on-chain can tell.
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(address(usdt));
        m[0] = 1;
        bytes32 divergent = vault.routeCommitment(H, agent, t, f, w, 1 ether, m, FUTURE);

        vm.prank(agent);
        anchor.anchor(H, divergent, 0);
        vm.prank(agent);
        vault.executeAndRoute{ value: 1 ether }(H, t, f, w, m, FUTURE);

        // Fully consistent on-chain record for an execution that contradicts
        // the signature.
        assertTrue(vault.consumed(agent, H));
        assertEq(anchor.execCommitmentOf(agent, H), divergent);
    }

    /// CONTROL: prove the executor really does enforce anchor==params, i.e. the
    /// gap is the anchor's freedom, not a missing check in the vault.
    function test_PoC_Control_VaultStillRejectsUnanchoredParams() public {
        bytes32 H = keccak256("control");
        pq.setAttested(H, true);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(address(usdc));
        bytes32 c = vault.routeCommitment(H, agent, t, f, w, 1 ether, m, FUTURE);
        vm.prank(agent);
        anchor.anchor(H, c, 0);

        m[0] = 12345;                            // deviate at execution time
        vm.prank(agent);
        vm.expectRevert();
        vault.executeAndRoute{ value: 1 ether }(H, t, f, w, m, FUTURE);
    }
}
