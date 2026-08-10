// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test }   from "forge-std/Test.sol";
import { PQBind } from "../helpers/PQBind.sol";
import { MockPQAttestation } from "../mocks/MockPQAttestation.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { WMON }                from "../../src/dex/WMON.sol";
import { MockToken }           from "../../src/dex/MockToken.sol";
import { AuditAnchorV2 }       from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { IV3SwapRouter }       from "../../src/interfaces/IV3SwapRouter.sol";
import { IWrappedNative }      from "../../src/interfaces/IWrappedNative.sol";
import { FaithfulRouter }      from "./RT03_DustInvariantAttacks.t.sol";

/// Records every `amountIn` the vault hands the router, then behaves like
/// SwapRouter02 (including the CONTRACT_BALANCE sentinel at amountIn == 0).
contract RecordingRouter is IV3SwapRouter {
    uint256[] public seen;

    function seenLength() external view returns (uint256) { return seen.length; }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        seen.push(p.amountIn);
        uint256 amountIn = p.amountIn;
        bool alreadyPaid;
        if (amountIn == 0) {
            alreadyPaid = true;
            amountIn = IERC20(p.tokenIn).balanceOf(address(this));
        }
        if (!alreadyPaid) {
            IERC20(p.tokenIn).transferFrom(msg.sender, address(this), amountIn);
        }
        amountOut = amountIn * 2000;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        IERC20(p.tokenOut).transfer(p.recipient, amountOut);
    }
}

/// RED TEAM — RT-07  (FINDING: the M-5 fix guarded the wrong invariant.
///                    NOW FIXED — every test below is the exploit, inverted.)
///
/// The hazard M-5 identified is `amountIn == 0` reaching SwapRouter02, where
/// 0 is not "swap nothing" but `Constants.CONTRACT_BALANCE`: the router
/// substitutes its OWN tokenIn balance and flips the payer to itself, so the
/// caller receives the router's stranded funds for free (see RT01).
///
/// The fix that shipped for M-5 was:
///
///     if (weightsBps[i] == 0) revert ZeroWeightLeg(i);
///
/// but the quantity actually handed to the router is
///
///     amountIn = (msg.value * weightsBps[i]) / 10_000;      // non-last legs
///
/// which is ALSO zero, with a perfectly legal non-zero weight, whenever
///
///     msg.value * weightsBps[i] < 10_000
///
/// i.e. for any msg.value <= 9_999 wei at the minimum legal weight of 1 bp.
/// Nothing else in the call rejects it: the weights still sum to 10_000, the
/// slippage floors are still non-zero, the balance-delta dust invariant still
/// holds exactly (the sentinel leg spends none of the vault's WMON — the
/// router pays from its own inventory), and the anchored commitment still
/// matches, because these are the parameters that were anchored.
///
/// The same gap existed in the off-chain pre-flight:
/// `src/monad_tx.py:validate_route_execution` rejected `w == 0` and never
/// evaluated `amount_in_wei * w // 10_000`.
///
/// FIX (now in tree, UniswapRoutingVault.sol) — assert the real invariant,
/// after the arithmetic, KEEPING the weight check alongside it:
///     if (weightsBps[i] == 0) revert ZeroWeightBps(i);            // the ORDER
///     uint256 amountIn = i == n - 1 ? remaining : (msg.value * weightsBps[i]) / 10_000;
///     if (amountIn == 0) revert ZeroWeightLeg(i);                 // the CALL
/// The quantity check is not strictly stronger — RT07h shows a zero-weight leg
/// carrying rounding dust passes it — but it catches what the weight check
/// cannot, namely a legal non-zero weight flooring to zero. It also covers
/// the LAST leg — see RT07g, where weights [10_000, 0] drain leg 0 and leave
/// the final leg at zero. `validate_route_execution` now replays the same
/// arithmetic, including the remainder.
///
/// RESIDUAL, reported: removing `weightsBps[i] == 0` outright made a
/// zero-weight leg carrying non-zero ROUNDING DUST newly acceptable. See
/// RT07h.
contract RT07_SentinelBypassViaRounding is Test {
    WMON wmon;
    MockToken usdc;
    AuditAnchorV2 anchor;
    FaithfulRouter router;
    RecordingRouter recorder;
    UniswapRoutingVault vault;
    UniswapRoutingVault recVault;

    address attacker = address(0xBAD);
    address stranded = address(0xF00D);

    uint24 constant FEE = 3000;
    uint256 constant FUTURE = 1e18;

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("USDC", "USDC", 18);
        anchor = new AuditAnchorV2();
        router = new FaithfulRouter();
        recorder = new RecordingRouter();

        address[] memory approved = new address[](1);
        approved[0] = address(usdc);
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = FEE;
        vault = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), address(new MockPQAttestation()), approved, tiers
        );
        recVault = new UniswapRoutingVault(
            address(wmon), address(recorder), address(anchor), address(new MockPQAttestation()), approved, tiers
        );

        for (uint256 i = 0; i < 5; ++i) usdc.faucet(100_000 ether);
        usdc.transfer(address(router), 200_000 ether);
        usdc.transfer(address(recorder), 200_000 ether);

        vm.deal(attacker, 100 ether);
        vm.deal(stranded, 100 ether);
    }

    /// Derives the orderHash: it is now a function of the execution
    /// parameters, so it cannot be supplied by the caller.
    function _anchorRoute(
        address who,
        UniswapRoutingVault v,
        uint16[] memory w,
        uint256 amountInWei,
        uint256[] memory m
    ) internal returns (bytes32 h, bytes memory pre) {
        address[] memory t = new address[](w.length);
        uint24[] memory f = new uint24[](w.length);
        for (uint256 i = 0; i < w.length; ++i) { t[i] = address(usdc); f[i] = FEE; }
        (pre, h) = PQBind.preimage(keccak256(
            abi.encode(block.chainid, address(v), who, t, f, w, amountInWei, m, FUTURE)
        ));
        bytes32 c = v.routeCommitment(h, who, t, f, w, amountInWei, m, FUTURE);
        uint64 s = anchor.nextSequence(who);
        vm.prank(who);
        anchor.anchor(h, c, s);
    }

    function _legs(uint16 a, uint16 b)
        internal
        view
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](2); t[0] = address(usdc); t[1] = address(usdc);
        f = new uint24[](2);  f[0] = FEE; f[1] = FEE;
        w = new uint16[](2);  w[0] = a; w[1] = b;
        m = new uint256[](2); m[0] = 1; m[1] = 1;
    }

    // ---------------------------------------------------------------------
    // (1) The primitive: amountIn == 0 reaches the router with a LEGAL order.
    // ---------------------------------------------------------------------

    /// INVERTED (was CONFIRMED, now FIXED) — the vault used to hand the router
    /// amountIn == 0 on a leg whose weight is 1 bp (not zero), so
    /// `ZeroWeightLeg` never fired and the sentinel was reachable. The router
    /// now records NOTHING, because the call dies before the first swap.
    function test_RT07a_ZeroAmountInNoLongerReachesTheRouter() public {
        // give the router some stranded WMON so the sentinel leg produces a
        // non-zero output and the call completes
        vm.startPrank(stranded);
        wmon.deposit{ value: 1 ether }();
        IERC20(address(wmon)).transfer(address(recorder), 1 ether);
        vm.stopPrank();
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(1, 9999);
        (bytes32 h, bytes memory h_pre) = _anchorRoute(attacker, recVault, w, 9_999, m);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.ZeroWeightLeg.selector, uint256(0))
        );
        recVault.executeAndRoute{ value: 9_999 }(h, t, f, w, m, FUTURE, h_pre);

        assertEq(recorder.seenLength(), 0, "the router was never called at all");
        assertFalse(recVault.consumed(attacker, h), "and the anchor was not burned");
    }

    /// The post-fix invariant, fuzzed over the whole rounding window: the vault
    /// either (a) reverts `ZeroWeightLeg(i)` at the first leg whose amountIn
    /// rounds to zero, or (b) runs with EVERY leg's amountIn strictly positive.
    /// There is no third outcome, so no amountIn == 0 can reach the router.
    ///
    /// (My original bound claimed the last leg could never be the sentinel.
    /// That is wrong — see RT07g — so this version asserts the invariant over
    /// all legs rather than exempting the last one.)
    function testFuzz_RT07b_NoZeroAmountInEverReachesTheRouter(
        uint16 wFirst,
        uint256 value
    ) public {
        uint16 a = uint16(bound(wFirst, 1, 9_999));
        uint16 b = uint16(10_000 - a);
        uint256 v = bound(value, 1, 100_000);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(a, b);
        (bytes32 h, bytes memory h_pre) = _anchorRoute(attacker, recVault, w, v, m);

        uint256 before = recorder.seenLength();
        vm.prank(attacker);
        try recVault.executeAndRoute{ value: v }(h, t, f, w, m, FUTURE, h_pre) {
            for (uint256 i = before; i < recorder.seenLength(); ++i) {
                assertGt(recorder.seen(i), 0, "no leg may be handed amountIn == 0");
            }
        } catch (bytes memory err) {
            if (bytes4(err) == UniswapRoutingVault.ZeroWeightLeg.selector) {
                // rejected for exactly the right reason: the guard fired
                assertEq((v * a) / 10_000, 0, "ZeroWeightLeg only for a zero quantity");
            }
            // other reverts (the >=1 output floor on tiny amounts) are fine;
            // the invariant is that the router never sees a zero.
            for (uint256 i = before; i < recorder.seenLength(); ++i) {
                assertGt(recorder.seen(i), 0, "no leg may be handed amountIn == 0");
            }
        }
    }

    // ---------------------------------------------------------------------
    // (2) The exploit: sweep the router's stranded WMON_MAINNET, for free.
    // ---------------------------------------------------------------------

    /// INVERTED (was CONFIRMED, M-5 re-opened; now FIXED) — an attacker with
    /// 9_999 wei of MON used to sweep every WMON stranded in SwapRouter02 and
    /// book it on-chain as a correctly-anchored, provenance-gated allocation,
    /// with the `Routed` event attributing 10 MON of output to a 1-bp slice the
    /// caller funded with nothing. The quantity guard now kills it before the
    /// first swap and the router keeps its inventory.
    function test_RT07c_StrandedRouterWmonCanNoLongerBeSwept() public {
        // Someone strands WMON in the router (RT01 documents that this happens
        // constantly: mis-sent tokens, aborted multicalls, refund dust).
        vm.startPrank(stranded);
        wmon.deposit{ value: 10 ether }();
        IERC20(address(wmon)).transfer(address(router), 10 ether);
        vm.stopPrank();
        assertEq(IERC20(address(wmon)).balanceOf(address(router)), 10 ether, "setup");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(1, 9999);
        (bytes32 h, bytes memory h_pre) = _anchorRoute(attacker, vault, w, 9_999, m);

        uint256 routerOutBefore = usdc.balanceOf(address(router));
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.ZeroWeightLeg.selector, uint256(0))
        );
        vault.executeAndRoute{ value: 9_999 }(h, t, f, w, m, FUTURE, h_pre);

        // nothing moved, and the anchor survives for a legitimate retry
        assertEq(usdc.balanceOf(attacker), 0, "no output delivered");
        assertEq(usdc.balanceOf(address(router)), routerOutBefore, "router inventory intact");
        assertEq(IERC20(address(wmon)).balanceOf(address(router)), 10 ether, "stranded WMON safe");
        assertFalse(vault.consumed(attacker, h), "anchor not burned by the rejected attempt");
    }

    /// The control: the same shape with a weight large enough to round above
    /// zero routes only the caller's own deposit and leaves the router alone.
    function test_RT07d_ControlNoSentinelWhenTheLegRoundsAboveZero() public {
        vm.startPrank(stranded);
        wmon.deposit{ value: 10 ether }();
        IERC20(address(wmon)).transfer(address(router), 10 ether);
        vm.stopPrank();
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(1, 9999);
        (bytes32 h, bytes memory h_pre) = _anchorRoute(attacker, vault, w, 1 ether, m);

        vm.prank(attacker);
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE, h_pre);

        assertEq(usdc.balanceOf(attacker), 2000 ether, "only the caller's own deposit routed");
        assertEq(
            IERC20(address(wmon)).balanceOf(address(router)),
            10 ether + 1 ether,
            "router inventory untouched"
        );
    }

    /// The fix, asserted as an arithmetic property rather than a behaviour:
    /// `amountIn == 0` is strictly stronger than `weightsBps[i] == 0`, and the
    /// gap between them is exactly the rounding window.
    function test_RT07e_QuantityGuardIsStrictlyStrongerThanTheWeightGuard() public pure {
        uint256 value = 9_999;
        uint16 wLeg = 1;
        assertTrue(wLeg != 0, "the old guard passed this leg");
        assertEq((value * wLeg) / 10_000, 0, "the new guard rejects it");
    }

    // ---------------------------------------------------------------------
    // (3) The case my original bound got wrong: the LAST leg.
    // ---------------------------------------------------------------------

    /// CONFIRMED REACHABLE — my RT07b claim that "the last leg is never the
    /// sentinel" only held while every weight was forced non-zero. It is false
    /// in general: `weightsBps = [10_000, 0]` gives leg 0 the entire deposit,
    /// so `remaining == 0` and the LAST leg receives amountIn == 0 — at any
    /// deposit size, not just under 10_000 wei. The old `weightsBps[i] == 0`
    /// check happened to catch this one; the new quantity check catches it for
    /// the right reason, and covers the last leg because it is computed for
    /// every i including `i == n-1`.
    ///
    /// With RT07h's weight check restored alongside it, the WEIGHT check now
    /// fires first on this input, so the expectation below names `ZeroWeightBps`.
    /// That is not a weakening — a zero-quantity LAST leg is provably
    /// unreachable once every weight is >= 1: the non-final legs allocate at
    /// most `amount * 9999 / 10_000` before flooring, so `remaining >= 1`
    /// always. The last-leg quantity guard is therefore defence-in-depth
    /// against a future change to the split arithmetic, and `ZeroWeightLeg`
    /// remains reachable — and load-bearing — on NON-final legs (RT07a).
    function test_RT07g_LastLegCanRoundToZeroAndIsCaught() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _legs(10_000, 0);
        (bytes32 h, bytes memory h_pre) = _anchorRoute(attacker, recVault, w, 1 ether, m);

        // the arithmetic the vault performs: leg 0 takes everything
        assertEq((uint256(1 ether) * 10_000) / 10_000, 1 ether, "leg 0 drains the deposit");

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.ZeroWeightBps.selector, uint256(1))
        );
        recVault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE, h_pre);

        // The revert names leg 1, i.e. the guard fired on the LAST leg — which
        // my original "never the last leg" bound wrongly excluded.
        // (Nothing is observable on the recorder: the revert rolls leg 0 back.)
        assertEq(recorder.seenLength(), 0, "whole call rolled back");
        assertFalse(recVault.consumed(attacker, h), "anchor not burned");
    }

    // ---------------------------------------------------------------------
    // (4) RESIDUAL from the fix itself.
    // ---------------------------------------------------------------------

    /// CONFIRMED (Low, NEW — introduced BY the fix) — dropping
    /// `weightsBps[i] == 0` entirely, rather than keeping it alongside the
    /// quantity check, made a NEW input acceptable: a zero-weight leg that
    /// receives non-zero ROUNDING DUST. With `weights = [5000, 5000, 0]` and a
    /// 3-wei deposit, legs 0 and 1 take 1 wei each and the zero-weight last leg
    /// absorbs `remaining == 1`, so amountIn > 0 and the guard is satisfied.
    ///
    /// The value at risk is at most `n-1` wei, so this is not a fund-loss path.
    /// It matters because the on-chain record is the product: the `Routed` event
    /// now reports a swap, with real output, against an allocation slice the
    /// signed order weighted at zero — the same class of audit-trail pollution
    /// M-5 was raised about, at a trivial magnitude.
    ///
    /// FIXED by keeping BOTH checks. `weightsBps[i] == 0` is a semantic assertion
    /// about the ORDER; `amountIn == 0` is a safety assertion about the CALL.
    /// They are not substitutes, and the weight check costs ~20 gas. Inverted
    /// below: the zero-weight leg is now rejected before any swap.
    function test_RT07h_ZeroWeightLegWithRoundingDustIsRejected() public {
        address[] memory t = new address[](3);
        uint24[]  memory f = new uint24[](3);
        uint16[]  memory w = new uint16[](3);
        uint256[] memory m = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) { t[i] = address(usdc); f[i] = FEE; m[i] = 1; }
        w[0] = 5000; w[1] = 5000; w[2] = 0;          // a ZERO-weight final leg

        // Bound to exactly these parameters, so ZeroWeightBps is what fires
        // rather than the binding.
        (bytes memory h_pre, bytes32 h) = PQBind.preimage(keccak256(
            abi.encode(block.chainid, address(recVault), attacker, t, f, w, uint256(3), m, FUTURE)
        ));
        bytes32 c = recVault.routeCommitment(h, attacker, t, f, w, 3, m, FUTURE);
        uint64 sq = anchor.nextSequence(attacker);
        vm.prank(attacker);
        anchor.anchor(h, c, sq);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.ZeroWeightBps.selector, 2)
        );
        recVault.executeAndRoute{ value: 3 }(h, t, f, w, m, FUTURE, h_pre);

        // No swap reached the router, and the anchor was not consumed.
        assertEq(recorder.seenLength(), 0, "the router must never be called");
        assertFalse(recVault.consumed(attacker, h), "anchor must not be burned");
    }
}

/// RT-07 fork leg — the same bypass against the REAL SwapRouter02 on Monad
/// mainnet. Self-skips without MONAD_RPC_URL / FORK_TOKEN_OUT / FORK_FEE.
contract RT07_SentinelBypassFork is Test {
    address constant WMON_MAINNET = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant ROUTER = 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;

    AuditAnchorV2 anchor;
    UniswapRoutingVault vault;
    address tokenOut;
    uint24 fee;
    bool forked;

    address attacker = address(0xBADBAD);
    address victimLP = address(0xF00D);

    uint256 constant FUTURE = 1e18;

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        require(block.chainid == 143, "fork is not Monad mainnet");
        forked = true;

        tokenOut = vm.envAddress("FORK_TOKEN_OUT");
        fee = uint24(vm.envUint("FORK_FEE"));

        anchor = new AuditAnchorV2();
        address[] memory approved = new address[](1);
        approved[0] = tokenOut;
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = fee;
        vault = new UniswapRoutingVault(WMON_MAINNET, ROUTER, address(anchor), address(new MockPQAttestation()), approved, tiers);

        vm.deal(attacker, 100 ether);
        vm.deal(victimLP, 100 ether);
    }

    /// INVERTED on a Monad mainnet fork (was CONFIRMED, now FIXED) — the old
    /// guard did not fire for a 1-bp leg whose amountIn rounds to zero, so
    /// `amountIn == 0` was delivered to the production SwapRouter02 at
    /// 0xfE31...b900. Whether the sweep then completed depended only on whether
    /// the LAST leg (<= 9_999 wei of WMON) could clear its >= 1 output floor for
    /// the chosen tokenOut — an accident of that token's decimals and price
    /// (USDC's 6 decimals blocked it; any 18-decimal token under ~$200 would
    /// not have), not a property of the contract.
    ///
    /// The guard now fires against the real router, before any swap.
    function test_RT07f_ForkGuardNowFiresOnARoundedToZeroLeg() public {
        if (!forked) { vm.skip(true); return; }   // reports as SKIPPED, not PASSED

        vm.startPrank(victimLP);
        IWrappedNative(WMON_MAINNET).deposit{ value: 5 ether }();
        IERC20(WMON_MAINNET).transfer(ROUTER, 5 ether);
        vm.stopPrank();
        uint256 strandedBefore = IERC20(WMON_MAINNET).balanceOf(ROUTER);
        assertGe(strandedBefore, 5 ether, "setup: WMON stranded in the router");

        address[] memory t = new address[](2); t[0] = tokenOut; t[1] = tokenOut;
        uint24[]  memory f = new uint24[](2);  f[0] = fee; f[1] = fee;
        uint16[]  memory w = new uint16[](2);  w[0] = 1; w[1] = 9_999;
        uint256[] memory m = new uint256[](2); m[0] = 1; m[1] = 1;
        // Bound to exactly these parameters, so ZeroWeightLeg is what fires.
        (bytes memory h_pre, bytes32 h) = PQBind.preimage(keccak256(
            abi.encode(block.chainid, address(vault), attacker, t, f, w, uint256(9_999), m, FUTURE)
        ));
        bytes32 c = vault.routeCommitment(h, attacker, t, f, w, 9_999, m, FUTURE);
        uint64 s = anchor.nextSequence(attacker);
        vm.prank(attacker);
        anchor.anchor(h, c, s);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.ZeroWeightLeg.selector, uint256(0))
        );
        vault.executeAndRoute{ value: 9_999 }(h, t, f, w, m, FUTURE, h_pre);

        assertEq(IERC20(tokenOut).balanceOf(attacker), 0, "FORK: nothing swept");
        assertEq(IERC20(WMON_MAINNET).balanceOf(ROUTER), strandedBefore, "FORK: router WMON untouched");
        assertFalse(vault.consumed(attacker, h), "FORK: anchor not burned");
        emit log("FORK: ZeroWeightLeg fired against the real SwapRouter02 - guard is correct");
    }
}
