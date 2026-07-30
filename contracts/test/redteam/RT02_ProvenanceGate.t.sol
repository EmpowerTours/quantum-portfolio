// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 }  from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { WMON }          from "../../src/dex/WMON.sol";
import { MockToken }     from "../../src/dex/MockToken.sol";
import { AuditAnchorV2 } from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { MorphoSupplyAdapter } from "../../src/MorphoSupplyAdapter.sol";
import { MarketParams }        from "../../src/interfaces/IMorpho.sol";
import { MockV3SwapRouter }    from "../mocks/MockV3SwapRouter.sol";

contract RT02Morpho {
    function supply(MarketParams calldata p, uint256 assets, uint256, address, bytes calldata)
        external
        returns (uint256, uint256)
    {
        MockToken(p.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, assets);
    }
}

/// RED TEAM — RT-02  (findings M-6 and L-1, now FIXED — these assert the fix)
///
/// ORIGINAL EXPLOIT (against AuditAnchor V1 + the pre-fix executors):
///   The provenance gate was `ANCHOR.lastHash(msg.sender) == orderHash`. That
///   is a PERSISTENT flag, not a consumable authorisation, and it committed to
///   NONE of the execution parameters. Proven against V1:
///     a) one anchor authorised an unbounded number of executions, forever;
///     b) those executions could carry completely different allocations,
///        amounts, tokens and slippage floors from the order that was
///        anchored — 8 MON was deployed across three allocations sharing
///        nothing, all reporting the same orderHash, with nextSequence == 1;
///     c) the same anchor simultaneously authorised the routing vault AND the
///        Morpho adapter — one audit record, two unrelated on-chain effects;
///     d) (L-1) the single `lastHash` slot meant anchoring order N+1 stranded
///        any in-flight execution of order N, so a pipelining agent silently
///        dropped trades.
///
/// FIX: AuditAnchorV2 stores `execCommitmentOf[anchorer][orderHash]`, a
///      keccak256 over the exact execution parameters, keyed by membership
///      rather than recency. Each executor recomputes the commitment from its
///      own calldata (`ExecutionNotAnchored`) and marks the anchor used
///      (`AnchorAlreadyConsumed`).
contract RT02_ProvenanceGate is Test {
    WMON wmon;
    MockToken usdc;
    MockToken usdt;
    AuditAnchorV2 anchor;
    MockV3SwapRouter router;
    UniswapRoutingVault vault;
    MorphoSupplyAdapter adapter;
    RT02Morpho morpho;

    address agent = address(0xA6E17);

    uint24 constant FEE = 3000;
    uint256 constant FUTURE = 1e18;

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("USDC", "USDC", 18);
        usdt = new MockToken("USDT", "USDT", 18);
        anchor = new AuditAnchorV2();
        router = new MockV3SwapRouter();
        morpho = new RT02Morpho();

        address[] memory approved = new address[](2);
        approved[0] = address(usdc);
        approved[1] = address(usdt);
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = FEE;
        vault = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), approved, tiers
        );

        bytes32[] memory markets = new bytes32[](1);
        markets[0] = keccak256(abi.encode(_market()));
        adapter = new MorphoSupplyAdapter(address(morpho), address(anchor), approved, markets);

        router.setRate(2000, 1);
        usdc.faucet(100_000 ether);
        usdt.faucet(100_000 ether);
        usdc.transfer(address(router), 50_000 ether);
        usdt.transfer(address(router), 50_000 ether);

        vm.deal(agent, 100 ether);
    }

    function _market() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(usdc),
            collateralToken: address(usdt),
            oracle: address(0xDEAD),
            irm: address(0xBEEF),
            lltv: 86e16
        });
    }

    function _one(address tok)
        internal
        pure
        returns (address[] memory t, uint24[] memory f, uint16[] memory ws, uint256[] memory m)
    {
        t = new address[](1); t[0] = tok;
        f = new uint24[](1);  f[0] = FEE;
        ws = new uint16[](1); ws[0] = 10_000;
        m = new uint256[](1); m[0] = 1;      // non-zero: ZeroSlippageFloor guard
    }

    function _anchorRoute(
        bytes32 h,
        address[] memory t,
        uint24[] memory f,
        uint16[] memory w,
        uint256 amountInWei,
        uint256[] memory m
    ) internal {
        bytes32 c = vault.routeCommitment(h, agent, t, f, w, amountInWei, m, FUTURE);
        uint64 _seq = anchor.nextSequence(agent);
        vm.prank(agent);
        anchor.anchor(h, c, _seq);
    }

    /// INVERTED (a)+(b) — an anchor is now single-use AND parameter-bound.
    /// The V1 sequence "one anchor, three divergent executions" now dies at
    /// the second step; a verbatim replay dies at the consumption check.
    function test_RT02a_OneAnchorNoLongerAuthorisesDivergentExecutions() public {
        bytes32 orderHash = keccak256("order-42");

        (address[] memory t1, uint24[] memory f1, uint16[] memory w1, uint256[] memory m1) =
            _one(address(usdc));
        _anchorRoute(orderHash, t1, f1, w1, 1 ether, m1);

        // execution 1 — exactly what was anchored: still works.
        vm.prank(agent);
        vault.executeAndRoute{ value: 1 ether }(orderHash, t1, f1, w1, m1, FUTURE);
        assertEq(usdc.balanceOf(agent), 1 ether * 2000, "the anchored trade executes");

        // execution 2 — V1 allowed this: a DIFFERENT token and amount under the
        // same "provenance". Now the commitment mismatch is caught first.
        (address[] memory t2, uint24[] memory f2, uint16[] memory w2, uint256[] memory m2) =
            _one(address(usdt));
        bytes32 anchored = anchor.execCommitmentOf(agent, orderHash);
        bytes32 divergent = vault.routeCommitment(orderHash, agent, t2, f2, w2, 5 ether, m2, FUTURE);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapRoutingVault.ExecutionNotAnchored.selector, divergent, anchored
            )
        );
        vault.executeAndRoute{ value: 5 ether }(orderHash, t2, f2, w2, m2, FUTURE);

        // execution 3 — a VERBATIM replay of the authorised trade. V1 allowed
        // unlimited repeats; now the anchor is spent.
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapRoutingVault.AnchorAlreadyConsumed.selector, orderHash
            )
        );
        vault.executeAndRoute{ value: 1 ether }(orderHash, t1, f1, w1, m1, FUTURE);

        assertEq(usdt.balanceOf(agent), 0, "the divergent allocation never executed");
        assertEq(usdc.balanceOf(agent), 1 ether * 2000, "and the replay added nothing");
    }

    /// INVERTED (c) — one anchor can no longer actuate two different contracts.
    /// The route and supply commitment shapes differ, so an anchor minted for
    /// the vault is structurally unusable at the adapter.
    function test_RT02c_OneAnchorCannotGateBothVaultAndMorphoAdapter() public {
        bytes32 orderHash = keccak256("order-99");

        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _one(address(usdc));
        _anchorRoute(orderHash, t, f, w, 1 ether, m);

        vm.prank(agent);
        vault.executeAndRoute{ value: 1 ether }(orderHash, t, f, w, m, FUTURE);

        // Same hash, no re-anchor: the adapter refuses it.
        vm.startPrank(agent);
        usdc.approve(address(adapter), type(uint256).max);
        bytes32 anchored = anchor.execCommitmentOf(agent, orderHash);
        bytes32 supplyC  = adapter.supplyCommitment(orderHash, agent, _market(), 1000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoSupplyAdapter.ExecutionNotAnchored.selector, supplyC, anchored
            )
        );
        adapter.supply(orderHash, _market(), 1000 ether, 1000 ether);
        vm.stopPrank();
    }

    /// INVERTED (d) — L-1 is gone. Anchoring the NEXT order no longer strands
    /// the previous one: commitments are keyed per (anchorer, orderHash), so a
    /// pipelining agent can anchor N and N+1 and still execute N.
    function test_RT02d_PipelinedAnchorsNoLongerStrandEachOther() public {
        bytes32 orderN  = keccak256("order-N");
        bytes32 orderN1 = keccak256("order-N+1");

        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _one(address(usdc));
        _anchorRoute(orderN, t, f, w, 1 ether, m);

        // The next order is anchored while route(N) is still in flight.
        (address[] memory t2, uint24[] memory f2, uint16[] memory w2, uint256[] memory m2) =
            _one(address(usdt));
        _anchorRoute(orderN1, t2, f2, w2, 2 ether, m2);

        // V1 reverted AnchorNotFound here. V2 executes both, in either order.
        vm.prank(agent);
        vault.executeAndRoute{ value: 1 ether }(orderN, t, f, w, m, FUTURE);
        vm.prank(agent);
        vault.executeAndRoute{ value: 2 ether }(orderN1, t2, f2, w2, m2, FUTURE);

        assertEq(usdc.balanceOf(agent), 1 ether * 2000, "order N executed");
        assertEq(usdt.balanceOf(agent), 2 ether * 2000, "order N+1 executed");
        assertEq(anchor.lastHash(agent), orderN1, "audit chain still records the latest");
    }

    /// UNCHANGED negative — an attacker still cannot touch another address's
    /// anchor state; commitments are namespaced by anchorer.
    function test_RT02e_ThirdPartyCannotAffectVictimAnchorState() public {
        address attacker = address(0xBAD);
        bytes32 h = keccak256("victim-order");

        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _one(address(usdc));
        _anchorRoute(h, t, f, w, 1 ether, m);
        bytes32 victimCommitment = anchor.execCommitmentOf(agent, h);

        vm.prank(attacker);
        anchor.anchor(h, keccak256("attacker-commitment"), 0);

        assertEq(anchor.execCommitmentOf(agent, h), victimCommitment, "victim's gate untouched");
        assertEq(anchor.nextSequence(agent), 1);
        assertEq(anchor.lastHash(agent), h);
    }
}
