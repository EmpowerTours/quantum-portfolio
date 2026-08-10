// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test }   from "forge-std/Test.sol";
import { MockPQAttestation } from "../mocks/MockPQAttestation.sol";
import { PQBind } from "../helpers/PQBind.sol";
import { PQExecBinding } from "../../src/PQExecBinding.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { WMON }                from "../../src/dex/WMON.sol";
import { MockToken }           from "../../src/dex/MockToken.sol";
import { AuditAnchorV2 }       from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { MorphoSupplyAdapter } from "../../src/MorphoSupplyAdapter.sol";
import { MarketParams }        from "../../src/interfaces/IMorpho.sol";
import { FaithfulRouter }      from "./RT03_DustInvariantAttacks.t.sol";
import { RT06Morpho }          from "./RT06_V2BindingSurface.t.sol";

/// RED TEAM — RT-08: domain separation of the execution commitment.
///
/// ORIGINAL FINDING (now FIXED — RT08a/b/c below are the exploits, inverted
/// and re-run against the fix). The commitment hashed ONLY the trade
/// parameters:
///
///     keccak256(abi.encode(user, tokenOuts, feeTiers, weightsBps,
///                          amountInWei, amountOutMin, deadline))
///     keccak256(abi.encode(user, MarketParams, maxAssets))
///
/// Absent from both preimages: the executing contract's address and the chain
/// id. Single-use enforcement (`consumed[user][orderHash]`) lives in the
/// EXECUTOR, while the authorisation (`execCommitmentOf[user][orderHash]`)
/// lives in the SHARED AuditAnchorV2. The stated invariant —
///
///     "An anchor authorises exactly one execution" (UniswapRoutingVault)
///
/// therefore held per executor DEPLOYMENT, not per anchor. Because the
/// documented upgrade path is literally "to add a token, deploy a new vault"
/// and "to add a market, deploy a new adapter", a second deployment against
/// the same anchor made every anchor ever written spendable a second time —
/// and again on every chain the contracts were deployed to.
///
/// FIX (in tree): `block.chainid` and `address(this)` now lead both preimages.
///
/// SECOND FINDING (also FIXED — RT08e/f below are that exploit, inverted).
/// After the chain/executor fix the commitment still did not bind the
/// `orderHash` it was filed under, while `consumed` IS keyed by orderHash. One
/// authorised execution was therefore spendable under N distinct orderHashes
/// on a SINGLE vault, and on the adapter it multiplied the authorised ceiling.
/// `orderHash` now leads both preimages after the chain and the executor, so
/// the commitment identifies the ORDER, not merely the trade.
///
/// Preimage layout now under test (10 leading words):
///     chainid | address(this) | orderHash | user | ...
///
/// THIRD LAYER (RT12, and why several tests below assert a different revert
/// than they used to). The executor is now handed the PQ-signed order's
/// canonical bytes and requires that `sha256(preimage) == orderHash` AND that
/// the `exec_commitment` inside those bytes equals a hash it recomputes from
/// its own calldata — a hash that ALSO leads with `block.chainid` and
/// `address(this)`. Two consequences for this file:
///
///   * an orderHash can no longer be invented. It is DERIVED from the
///     execution parameters, so "the same order at a second vault" is not
///     expressible as one hash, and two orders with identical parameters are
///     the SAME order. Where a test needs two independent orders it now varies
///     a parameter (the deposit, the ceiling) to keep them apart.
///
///   * the chain/executor separation is enforced TWICE, and the PQ binding
///     runs FIRST. A straight cross-vault replay therefore reverts
///     `ExecCommitmentMismatch` rather than `ExecutionNotAnchored`. That is a
///     strictly stronger rejection on the same axis, but it would hide the
///     anchor-layer property this file exists to pin, so RT08a and RT08b now
///     exercise BOTH layers explicitly.
contract RT08_CommitmentDomainSeparation is Test {
    WMON wmon;
    MockToken usdc;
    AuditAnchorV2 anchor;
    AuditAnchorV2 anchorB;            // a SECOND V2 anchor on the same chain
    FaithfulRouter router;
    RT06Morpho morpho;

    UniswapRoutingVault vaultV1;
    UniswapRoutingVault vaultV2;      // "deploy a new vault to add a token"
    MorphoSupplyAdapter adapterV1;
    MorphoSupplyAdapter adapterV2;    // "deploy a new adapter to add a market"

    address agent = address(0xA6E17);
    uint24 constant FEE = 3000;
    uint256 constant FUTURE = 1e18;

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("USDC", "USDC", 18);
        anchor = new AuditAnchorV2();
        anchorB = new AuditAnchorV2();
        router = new FaithfulRouter();
        morpho = new RT06Morpho();

        address[] memory approved = new address[](1);
        approved[0] = address(usdc);
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = FEE;

        vaultV1 = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), address(new MockPQAttestation()), approved, tiers
        );
        vaultV2 = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), address(new MockPQAttestation()), approved, tiers
        );

        bytes32[] memory markets = new bytes32[](1);
        markets[0] = keccak256(abi.encode(_market()));
        adapterV1 = new MorphoSupplyAdapter(address(morpho), address(anchor), address(new MockPQAttestation()), approved, markets);
        adapterV2 = new MorphoSupplyAdapter(address(morpho), address(anchor), address(new MockPQAttestation()), approved, markets);

        for (uint256 i = 0; i < 5; ++i) usdc.faucet(100_000 ether);
        usdc.transfer(address(router), 400_000 ether);

        vm.deal(agent, 1_000 ether);
    }

    function _market() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(usdc),
            collateralToken: address(0xC0),
            oracle: address(0xDEAD),
            irm: address(0xBEEF),
            lltv: 86e16
        });
    }

    function _one()
        internal
        view
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](1); t[0] = address(usdc);
        f = new uint24[](1);  f[0] = FEE;
        w = new uint16[](1);  w[0] = 10_000;
        m = new uint256[](1); m[0] = 1;
    }

    /// The exec_commitment a signer would embed for a routing call, and the
    /// orderHash that follows from it. Note it is parameterised by the VAULT:
    /// that is the whole point of RT08, now also enforced inside the signed
    /// bytes.
    function _routeParams(
        UniswapRoutingVault v,
        address   who,
        address[] memory t,
        uint24[]  memory f,
        uint16[]  memory w,
        uint256   value,
        uint256[] memory m
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(block.chainid, address(v), who, t, f, w, value, m, FUTURE)
        );
    }

    function _deriveRoute(
        UniswapRoutingVault v,
        address   who,
        address[] memory t,
        uint24[]  memory f,
        uint16[]  memory w,
        uint256   value,
        uint256[] memory m
    ) internal view returns (bytes32 h, bytes memory pre) {
        (pre, h) = PQBind.preimage(_routeParams(v, who, t, f, w, value, m));
    }

    function _supplyParams(MorphoSupplyAdapter a, address who, uint256 maxAssets)
        internal
        view
        returns (bytes32)
    {
        MarketParams memory p = _market();
        return keccak256(
            abi.encode(
                block.chainid, address(a), who, p.loanToken, p.collateralToken,
                p.oracle, p.irm, p.lltv, maxAssets
            )
        );
    }

    function _deriveSupply(MorphoSupplyAdapter a, address who, uint256 maxAssets)
        internal
        view
        returns (bytes32 h, bytes memory pre)
    {
        (pre, h) = PQBind.preimage(_supplyParams(a, who, maxAssets));
    }

    // =====================================================================
    // (a) one anchor, N executor deployments — INVERTED, now must FAIL
    // =====================================================================

    /// INVERTED (was CONFIRMED, now FIXED) — a single anchor was spent once on
    /// vaultV1 and then AGAIN on vaultV2, because `consumed` is per-vault and
    /// `execCommitmentOf` is shared and never cleared. With `address(this)` in
    /// the preimage the two vaults now compute DIFFERENT commitments, so the
    /// replay is rejected at the binding check.
    function test_RT08a_ReplayAcrossVaultDeploymentsIsNowRejected() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _one();

        // h1 IS the vaultV1 order: the executor's address is inside the hash.
        (bytes32 h1, bytes memory pre1) = _deriveRoute(vaultV1, agent, t, f, w, 1 ether, m);

        bytes32 cV1 = vaultV1.routeCommitment(h1, agent, t, f, w, 1 ether, m, FUTURE);
        bytes32 cV2 = vaultV2.routeCommitment(h1, agent, t, f, w, 1 ether, m, FUTURE);
        assertTrue(cV1 != cV2, "the commitment is now bound to the executor");

        uint64 s = anchor.nextSequence(agent);
        vm.prank(agent);
        anchor.anchor(h1, cV1, s);

        vm.prank(agent);
        vaultV1.executeAndRoute{ value: 1 ether }(h1, t, f, w, m, FUTURE, pre1);
        assertTrue(vaultV1.consumed(agent, h1), "spent on V1");

        // The replay that used to work, taken verbatim to the second vault. It
        // is now rejected one layer EARLIER than it used to be: the signed
        // exec_commitment carries the executor too, so vaultV2 recomputes a
        // different value from its own calldata and never reaches the anchor.
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                PQExecBinding.ExecCommitmentMismatch.selector,
                _routeParams(vaultV1, agent, t, f, w, 1 ether, m),   // what the signer signed
                _routeParams(vaultV2, agent, t, f, w, 1 ether, m)    // what vaultV2 recomputes
            )
        );
        vaultV2.executeAndRoute{ value: 1 ether }(h1, t, f, w, m, FUTURE, pre1);
        assertFalse(vaultV2.consumed(agent, h1), "not spendable a second time");

        // The ANCHOR-layer separation this test was originally written for is
        // still pinned, on its own: hand vaultV2 an order it CAN bind (h2), but
        // file it under a commitment minted in vaultV1's domain. The PQ check
        // passes, and `ExecutionNotAnchored` fires with exactly the two values
        // the original assertion named.
        (bytes32 h2, bytes memory pre2) = _deriveRoute(vaultV2, agent, t, f, w, 1 ether, m);
        assertTrue(h1 != h2, "one order per (executor, parameters) - never shared");
        bytes32 mintedForV1 = vaultV1.routeCommitment(h2, agent, t, f, w, 1 ether, m, FUTURE);
        bytes32 wantedByV2  = vaultV2.routeCommitment(h2, agent, t, f, w, 1 ether, m, FUTURE);

        s = anchor.nextSequence(agent);
        vm.prank(agent);
        anchor.anchor(h2, mintedForV1, s);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapRoutingVault.ExecutionNotAnchored.selector, wantedByV2, mintedForV1
            )
        );
        vaultV2.executeAndRoute{ value: 1 ether }(h2, t, f, w, m, FUTURE, pre2);

        assertFalse(vaultV2.consumed(agent, h2), "a V1-domain anchor is inert at V2");
        assertEq(usdc.balanceOf(agent), 2000 ether, "exactly one execution");
    }

    /// INVERTED (was CONFIRMED, now FIXED) — the same replay on the yield leg,
    /// which was the worse of the two because a standing max ERC20 approval to
    /// each adapter is the norm.
    function test_RT08b_ReplayAcrossAdapterDeploymentsIsNowRejected() public {
        // h1 IS the adapterV1 order — same reasoning as RT08a.
        (bytes32 h1, bytes memory pre1) = _deriveSupply(adapterV1, agent, 1000 ether);
        bytes32 cA1 = adapterV1.supplyCommitment(h1, agent, _market(), 1000 ether);
        bytes32 cA2 = adapterV2.supplyCommitment(h1, agent, _market(), 1000 ether);
        assertTrue(cA1 != cA2, "the commitment is now bound to the executor");

        uint64 s = anchor.nextSequence(agent);
        vm.prank(agent);
        anchor.anchor(h1, cA1, s);

        vm.startPrank(agent);
        usdc.faucet(3000 ether);
        usdc.approve(address(adapterV1), type(uint256).max);
        usdc.approve(address(adapterV2), type(uint256).max);
        adapterV1.supply(h1, _market(), 1000 ether, 1000 ether, pre1);

        // The replay, verbatim, at the second adapter — now stopped by the PQ
        // binding before the anchor is even read.
        vm.expectRevert(
            abi.encodeWithSelector(
                PQExecBinding.ExecCommitmentMismatch.selector,
                _supplyParams(adapterV1, agent, 1000 ether),
                _supplyParams(adapterV2, agent, 1000 ether)
            )
        );
        adapterV2.supply(h1, _market(), 1000 ether, 1000 ether, pre1);
        vm.stopPrank();

        // ...and the anchor-layer property on its own: an order adapterV2 CAN
        // bind, filed under a commitment minted in adapterV1's domain.
        (bytes32 h2, bytes memory pre2) = _deriveSupply(adapterV2, agent, 1000 ether);
        assertTrue(h1 != h2, "one order per (executor, parameters) - never shared");
        bytes32 mintedForA1 = adapterV1.supplyCommitment(h2, agent, _market(), 1000 ether);
        bytes32 wantedByA2  = adapterV2.supplyCommitment(h2, agent, _market(), 1000 ether);

        s = anchor.nextSequence(agent);
        vm.prank(agent);
        anchor.anchor(h2, mintedForA1, s);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoSupplyAdapter.ExecutionNotAnchored.selector, wantedByA2, mintedForA1
            )
        );
        adapterV2.supply(h2, _market(), 1000 ether, 1000 ether, pre2);

        assertFalse(adapterV2.consumed(agent, h2), "an A1-domain anchor is inert at A2");
        assertEq(usdc.balanceOf(address(morpho)), 1000 ether, "the ceiling was supplied ONCE");
    }

    // =====================================================================
    // (b) one anchor across BOTH executors — the question asked directly
    // =====================================================================

    /// NEGATIVE — one anchor can NOT be spent once on the vault and once on
    /// the adapter, and this holds for two independent reasons, both proved
    /// here rather than assumed:
    ///
    ///   1. STRUCTURAL. The two preimages can never be the same byte string.
    ///      `supplyCommitment` is 10 all-static words (chainid, address(this),
    ///      orderHash, user, the 5 inlined MarketParams fields, maxAssets) ==
    ///      exactly 320 bytes. `routeCommitment` is a 10-word head plus FOUR
    ///      length-prefixed array tails, so >= 320 + 4*32 == 448 bytes. Lengths
    ///      are disjoint at every input, so a collision would need a keccak
    ///      preimage break.
    ///
    ///   2. CONCRETE. `execCommitmentOf[user][orderHash]` holds one value, and
    ///      whichever executor it was minted for, the other rejects it.
    ///
    /// (RT02c asserts the concrete half against the old scheme; this pins the
    /// structural half against the new one, which is what CommitmentParity's
    /// executor/chain tests do not cover.)
    function testFuzz_RT08c_OneAnchorCannotBeSpentOnBothExecutors(
        uint8 n,
        uint256 amt,
        uint256 lltv,
        bytes32 oh
    ) public view {
        uint256 len = bound(n, 0, 8);
        address[] memory t = new address[](len);
        uint24[]  memory f = new uint24[](len);
        uint16[]  memory w = new uint16[](len);
        uint256[] memory m = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) { t[i] = address(usdc); f[i] = FEE; w[i] = 1; m[i] = 1; }

        MarketParams memory p = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(0xC0),
            oracle: address(0xDEAD),
            irm: address(0xBEEF),
            lltv: lltv
        });

        uint256 supplyLen =
            abi.encode(block.chainid, address(adapterV1), oh, agent, p, amt).length;
        uint256 routeLen = abi.encode(
            block.chainid, address(vaultV1), oh, agent, t, f, w, amt, m, FUTURE
        ).length;

        assertEq(supplyLen, 320, "supply preimage is 10 static words");
        assertGe(routeLen, 448, "route preimage always carries 4 array tails");
        assertTrue(supplyLen != routeLen, "preimages can never be the same byte string");
        assertTrue(
            vaultV1.routeCommitment(oh, agent, t, f, w, amt, m, FUTURE)
                != adapterV1.supplyCommitment(oh, agent, p, amt),
            "cross-executor collision"
        );
    }

    /// NEGATIVE — end-to-end: an anchor minted for the vault is rejected by the
    /// adapter and vice versa, and neither attempt burns the other's anchor.
    ///
    /// POST-RT12: the rejection moved from `ExecutionNotAnchored` to
    /// `ExecCommitmentMismatch`, and here that is not merely "one layer
    /// earlier" — `ExecutionNotAnchored` is now UNREACHABLE on this path. An
    /// orderHash is `sha256` of bytes carrying the exec_commitment, and a route
    /// commitment can never equal a supply commitment (RT08c), so no single
    /// orderHash can be bound at both executors. The anchor-layer property is
    /// therefore asserted directly against the anchor's storage below.
    function test_RT08d_AnchorMintedForOneExecutorIsInertAtTheOther() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _one();

        (bytes32 hR, bytes memory preR) = _deriveRoute(vaultV1, agent, t, f, w, 1 ether, m);
        bytes32 cR = vaultV1.routeCommitment(hR, agent, t, f, w, 1 ether, m, FUTURE);
        vm.prank(agent);
        anchor.anchor(hR, cR, 0);

        vm.startPrank(agent);
        usdc.faucet(2000 ether);
        usdc.approve(address(adapterV1), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                PQExecBinding.ExecCommitmentMismatch.selector,
                _routeParams(vaultV1, agent, t, f, w, 1 ether, m),   // a ROUTE order
                _supplyParams(adapterV1, agent, 1 ether)             // a SUPPLY execution
            )
        );
        adapterV1.supply(hR, _market(), 1 ether, 1 ether, preR);
        vm.stopPrank();
        assertFalse(adapterV1.consumed(agent, hR), "route anchor is inert at the adapter");
        // the original claim, as state: the one anchor slot for hR holds a
        // route commitment, which is not what the adapter would have demanded.
        assertEq(anchor.execCommitmentOf(agent, hR), cR, "one slot, one value");
        assertTrue(
            cR != adapterV1.supplyCommitment(hR, agent, _market(), 1 ether),
            "and the adapter would have rejected it too"
        );

        (bytes32 hS, bytes memory preS) = _deriveSupply(adapterV1, agent, 1000 ether);
        bytes32 cS = adapterV1.supplyCommitment(hS, agent, _market(), 1000 ether);
        vm.prank(agent);
        anchor.anchor(hS, cS, 1);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                PQExecBinding.ExecCommitmentMismatch.selector,
                _supplyParams(adapterV1, agent, 1000 ether),         // a SUPPLY order
                _routeParams(vaultV1, agent, t, f, w, 1 ether, m)    // a ROUTE execution
            )
        );
        vaultV1.executeAndRoute{ value: 1 ether }(hS, t, f, w, m, FUTURE, preS);
        assertFalse(vaultV1.consumed(agent, hS), "supply anchor is inert at the vault");
        assertEq(anchor.execCommitmentOf(agent, hS), cS, "one slot, one value");
        assertTrue(
            cS != vaultV1.routeCommitment(hS, agent, t, f, w, 1 ether, m, FUTURE),
            "and the vault would have rejected it too"
        );

        // each is still spendable at its own executor
        vm.prank(agent);
        vaultV1.executeAndRoute{ value: 1 ether }(hR, t, f, w, m, FUTURE, preR);
        vm.prank(agent);
        adapterV1.supply(hS, _market(), 1000 ether, 1000 ether, preS);
    }

    // =====================================================================
    // (c) STILL OPEN after the domain fix: orderHash is not in the preimage
    // =====================================================================

    /// INVERTED (was CONFIRMED, now FIXED) — the commitment bound the chain,
    /// the executor and the trade, but NOT the `orderHash` it was filed under,
    /// while `consumed` IS keyed by orderHash. Filing the SAME commitment under
    /// N distinct orderHashes therefore yielded N executions on ONE vault, with
    /// the anchor, the vault and the event log all reporting N legitimately-
    /// anchored, single-use executions. It was the M-6 failure mode through the
    /// other door: not divergent executions per anchor, but unlimited anchors
    /// per execution — and an off-chain verifier checking "orderHash is a real
    /// PQ-signed order AND its commitment matches" could not tell the
    /// duplicates apart, because every one of them passed both tests.
    ///
    /// With `orderHash` in the preimage, the commitment minted for order #0 is
    /// simply not the commitment any other orderHash computes, so the second
    /// filing is inert.
    function test_RT08e_ReAnchoringOneCommitmentUnderNewOrderHashesIsNowInert() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _one();

        (bytes32 h0, bytes memory pre0) = _deriveRoute(vaultV1, agent, t, f, w, 1 ether, m);
        bytes32 c0 = vaultV1.routeCommitment(h0, agent, t, f, w, 1 ether, m, FUTURE);

        vm.prank(agent);
        anchor.anchor(h0, c0, 0);
        vm.prank(agent);
        vaultV1.executeAndRoute{ value: 1 ether }(h0, t, f, w, m, FUTURE, pre0);
        assertEq(usdc.balanceOf(agent), 2000 ether, "the authorised execution runs once");

        // The replay: file the SAME commitment under four fresh orderHashes.
        //
        // The orderHash is now derived from the execution parameters, so four
        // "fresh" hashes require four distinct parameter sets — otherwise all
        // five are literally the same order and the second anchor reverts
        // AlreadyAnchored, testing nothing. The deposit is bumped by i wei,
        // which is the smallest change that keeps the orders independent while
        // leaving the attack shape identical: the SAME commitment `c0`, filed
        // under an orderHash it was not minted for.
        for (uint256 i = 1; i < 5; ++i) {
            uint256 value = 1 ether + i;
            (bytes32 h, bytes memory pre) = _deriveRoute(vaultV1, agent, t, f, w, value, m);
            uint64 sq = anchor.nextSequence(agent);
            vm.prank(agent);
            anchor.anchor(h, c0, sq);              // still permitted: the anchor is opaque

            bytes32 expected = vaultV1.routeCommitment(h, agent, t, f, w, value, m, FUTURE);
            assertTrue(expected != c0, "each orderHash has its own commitment now");

            vm.prank(agent);
            vm.expectRevert(
                abi.encodeWithSelector(
                    UniswapRoutingVault.ExecutionNotAnchored.selector, expected, c0
                )
            );
            vaultV1.executeAndRoute{ value: value }(h, t, f, w, m, FUTURE, pre);
            assertFalse(vaultV1.consumed(agent, h), "no second execution");
        }

        assertEq(usdc.balanceOf(agent), 2000 ether, "EXACTLY one execution, not five");
    }

    /// INVERTED (was CONFIRMED, now FIXED) — the same hole on the adapter, where
    /// it multiplied the authorised CEILING: an anchor for "up to 1000 USDC"
    /// became "up to 1000 USDC, N times".
    function test_RT08f_SupplyCeilingCanNoLongerBeMultipliedByReAnchoring() public {
        (bytes32 h0, bytes memory pre0) = _deriveSupply(adapterV1, agent, 1000 ether);
        bytes32 c0 = adapterV1.supplyCommitment(h0, agent, _market(), 1000 ether);

        vm.startPrank(agent);
        usdc.faucet(5000 ether);
        usdc.approve(address(adapterV1), type(uint256).max);
        vm.stopPrank();

        vm.prank(agent);
        anchor.anchor(h0, c0, 0);
        vm.prank(agent);
        adapterV1.supply(h0, _market(), 1000 ether, 1000 ether, pre0);

        // As in RT08e: the fresh orderHashes must differ in a parameter now
        // that the hash is derived, so the authorised CEILING is bumped by i
        // wei. The supplied `assets` stays at exactly 1000 ether, so the
        // quantity under test is unchanged and the ceiling-multiplication
        // attack keeps its original shape.
        for (uint256 i = 1; i < 4; ++i) {
            uint256 ceiling = 1000 ether + i;
            (bytes32 h, bytes memory pre) = _deriveSupply(adapterV1, agent, ceiling);
            uint64 sq = anchor.nextSequence(agent);
            vm.prank(agent);
            anchor.anchor(h, c0, sq);

            bytes32 expected = adapterV1.supplyCommitment(h, agent, _market(), ceiling);
            assertTrue(expected != c0, "each orderHash has its own commitment now");
            vm.prank(agent);
            vm.expectRevert(
                abi.encodeWithSelector(
                    MorphoSupplyAdapter.ExecutionNotAnchored.selector, expected, c0
                )
            );
            adapterV1.supply(h, _market(), 1000 ether, ceiling, pre);
        }

        assertEq(
            usdc.balanceOf(address(morpho)), 1000 ether,
            "the ceiling was supplied ONCE, not 4x"
        );
    }

    /// NEGATIVE — the complementary direction: `orderHash` in the preimage also
    /// means a commitment cannot be MOVED to a different order, so the
    /// (user, orderHash) slot and the trade it authorises are now welded
    /// together in both directions. Fuzzed.
    function testFuzz_RT08j_CommitmentIsBijectiveWithOrderHash(bytes32 ha, bytes32 hb)
        public
        view
    {
        vm.assume(ha != hb);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _one();
        assertTrue(
            vaultV1.routeCommitment(ha, agent, t, f, w, 1 ether, m, FUTURE)
                != vaultV1.routeCommitment(hb, agent, t, f, w, 1 ether, m, FUTURE),
            "identical trades under different orderHashes must not share a commitment"
        );
        assertTrue(
            adapterV1.supplyCommitment(ha, agent, _market(), 1000 ether)
                != adapterV1.supplyCommitment(hb, agent, _market(), 1000 ether),
            "same on the adapter"
        );
    }

    // =====================================================================
    // (d) residual domain axes: is the separation now COMPLETE?
    // =====================================================================

    /// NEGATIVE — the ANCHOR's address is not in the preimage, and does not
    /// need to be: each executor holds its anchor as an immutable and reads
    /// only that one. A commitment written into a different AuditAnchorV2 on
    /// the same chain is unreachable from a vault wired to the first, so a
    /// second anchor deployment does not widen the authorisation set.
    ///
    /// The converse — two vaults sharing ONE anchor — is what `address(this)`
    /// now separates (RT08a).
    function test_RT08g_ASecondAnchorDeploymentDoesNotWidenAuthorisation() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _one();
        // Derived, so the PQ binding is satisfied and the call reaches the
        // anchor lookup — which is the check this test is about.
        (bytes32 h, bytes memory pre) = _deriveRoute(vaultV1, agent, t, f, w, 1 ether, m);
        bytes32 c = vaultV1.routeCommitment(h, agent, t, f, w, 1 ether, m, FUTURE);

        // agent anchors on the WRONG V2 instance
        vm.prank(agent);
        anchorB.anchor(h, c, 0);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.AnchorNotFound.selector, h)
        );
        vaultV1.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE, pre);

        assertEq(address(vaultV1.ANCHOR()), address(anchor), "the anchor is immutable per vault");
    }

    /// NEGATIVE — `address(this)` cannot be reused on one chain. Two distinct
    /// executors at the same address is impossible: neither contract contains
    /// SELFDESTRUCT, and post-Cancun (EIP-6780, this repo's evm_version)
    /// SELFDESTRUCT only clears code when called in the same transaction as
    /// creation, so a CREATE2 slot occupied by a live vault can never be
    /// re-occupied by a different one.
    function test_RT08h_ExecutorAddressCannotBeRecycled() public view {
        assertTrue(address(vaultV1) != address(vaultV2), "distinct deployments, distinct domains");
        assertTrue(address(vaultV1).code.length > 0, "occupied and non-destructible");
        assertTrue(address(adapterV1).code.length > 0);
        // and the commitment differs by exactly that field
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _one();
        bytes32 oh = keccak256("layout");
        assertEq(
            vaultV1.routeCommitment(oh, agent, t, f, w, 1 ether, m, FUTURE),
            keccak256(
                abi.encode(
                    block.chainid, address(vaultV1), oh, agent, t, f, w,
                    uint256(1 ether), m, FUTURE
                )
            ),
            "preimage is exactly (chainid, executor, orderHash, user, ...)"
        );
    }

    /// NEGATIVE — chain binding, taken past the value CommitmentParity pins:
    /// fuzzed over chain ids, no two chains ever agree on a commitment.
    function testFuzz_RT08i_NoTwoChainIdsShareACommitment(uint64 a, uint64 b) public {
        vm.assume(a != b && a != 0 && b != 0);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _one();

        bytes32 oh = keccak256("chain-probe");
        vm.chainId(a);
        bytes32 ca = vaultV1.routeCommitment(oh, agent, t, f, w, 1 ether, m, FUTURE);
        bytes32 sa = adapterV1.supplyCommitment(oh, agent, _market(), 1000 ether);
        vm.chainId(b);
        assertTrue(
            ca != vaultV1.routeCommitment(oh, agent, t, f, w, 1 ether, m, FUTURE), "route"
        );
        assertTrue(sa != adapterV1.supplyCommitment(oh, agent, _market(), 1000 ether), "supply");
    }
}
