// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test }   from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { WMON }          from "../../src/dex/WMON.sol";
import { MockToken }     from "../../src/dex/MockToken.sol";
import { AuditAnchorV2 } from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { MorphoSupplyAdapter } from "../../src/MorphoSupplyAdapter.sol";
import { MarketParams }        from "../../src/interfaces/IMorpho.sol";
import { FaithfulRouter }      from "./RT03_DustInvariantAttacks.t.sol";

contract RT06Morpho {
    function supply(MarketParams calldata p, uint256 assets, uint256, address, bytes calldata)
        external
        returns (uint256, uint256)
    {
        IERC20(p.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, assets);
    }
}

/// RED TEAM — RT-06: does the binding/consumption change itself introduce new
/// attack surface? Three directed probes (front-run grief, commitment
/// collision, consumption DoS) plus what they turned up.
contract RT06_V2BindingSurface is Test {
    WMON wmon;
    MockToken usdc;
    MockToken usdt;
    AuditAnchorV2 anchor;
    FaithfulRouter router;
    UniswapRoutingVault vault;
    MorphoSupplyAdapter adapter;
    RT06Morpho morpho;

    address agent    = address(0xA6E17);
    address attacker = address(0xBAD);

    uint24 constant FEE = 3000;
    /// A fixed orderHash for the pure hash-shape probes, which are about the
    /// preimage layout rather than about any particular order.
    bytes32 constant H0 = bytes32(uint256(0x11));
    uint256 constant FUTURE = 1e18;

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("USDC", "USDC", 18);
        usdt = new MockToken("USDT", "USDT", 18);
        anchor = new AuditAnchorV2();
        router = new FaithfulRouter();
        morpho = new RT06Morpho();

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

        usdc.faucet(100_000 ether);
        usdt.faucet(100_000 ether);
        usdc.transfer(address(router), 50_000 ether);
        usdt.transfer(address(router), 50_000 ether);

        vm.deal(agent, 1_000 ether);
        vm.deal(attacker, 1_000 ether);
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
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](1); t[0] = tok;
        f = new uint24[](1);  f[0] = FEE;
        w = new uint16[](1);  w[0] = 10_000;
        m = new uint256[](1); m[0] = 1;
    }

    function _anchorRoute(
        address who,
        bytes32 h,
        address[] memory t,
        uint24[] memory f,
        uint16[] memory w,
        uint256 amountInWei,
        uint256[] memory m
    ) internal {
        bytes32 c = vault.routeCommitment(h, who, t, f, w, amountInWei, m, FUTURE);
        uint64 _seq = anchor.nextSequence(who);
        vm.prank(who);
        anchor.anchor(h, c, _seq);
    }

    // ================= PROBE 1: third-party anchor front-run =================

    /// NEGATIVE — an attacker cannot grief a victim's anchor by front-running
    /// it. `execCommitmentOf` and `nextSequence` are both namespaced by
    /// msg.sender, and `AlreadyAnchored` only fires against the caller's own
    /// slot, so racing the same orderHash writes to a disjoint mapping entry.
    function test_RT06a_FrontRunningAnAnchorCannotGriefTheVictim() public {
        bytes32 h = keccak256("contested-order");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _one(address(usdc));

        // Attacker front-runs, anchoring the SAME orderHash first, with a
        // commitment designed to authorise a different trade.
        bytes32 poison = vault.routeCommitment(h, attacker, t, f, w, 999 ether, m, FUTURE);
        vm.prank(attacker);
        anchor.anchor(h, poison, 0);

        // Victim anchors the same hash afterwards: unaffected.
        _anchorRoute(agent, h, t, f, w, 1 ether, m);

        vm.prank(agent);
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE);
        assertEq(usdc.balanceOf(agent), 2000 ether, "victim executed normally");

        // And the attacker's poisoned anchor authorises nothing of the victim's.
        assertFalse(vault.consumed(attacker, h), "attacker's slot is disjoint");
    }

    /// NEGATIVE — an attacker cannot consume a victim's anchor either: the
    /// commitment binds `user`, and `consumed` is keyed by msg.sender.
    function test_RT06b_AttackerCannotConsumeVictimsAnchor() public {
        bytes32 h = keccak256("victim-order");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _one(address(usdc));
        _anchorRoute(agent, h, t, f, w, 1 ether, m);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingVault.AnchorNotFound.selector, h));
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE);

        // victim's anchor is still spendable
        vm.prank(agent);
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE);
        assertEq(usdc.balanceOf(agent), 2000 ether);
    }

    // ============== PROBE 2: commitment collisions via abi.encode ==============

    /// NEGATIVE — `abi.encode` is length-prefixed and offset-based, so array
    /// boundaries cannot be shifted between the now-FOUR dynamic arrays
    /// (tokenOuts, feeTiers, weightsBps, amountOutMin). Fuzzed over
    /// independently-varying lengths — routeCommitment itself does not require
    /// them to be equal, so mismatched shapes are reachable at anchor time.
    function _rc(uint256 n, uint256 nMin, uint256 seed) internal view returns (bytes32) {
        (address[] memory t, uint24[] memory f, uint16[] memory w) = _mk(n, seed);
        return vault.routeCommitment(H0, agent, t, f, w, 1 ether, _mkMin(nMin), FUTURE);
    }

    function testFuzz_RT06c_RouteCommitmentIsInjectiveAcrossArrayBoundaries(
        uint8 nA,
        uint8 nB,
        uint8 nMinA,
        uint8 nMinB,
        uint256 seed
    ) public view {
        uint256 a = bound(nA, 1, 6);
        uint256 b = bound(nB, 1, 6);
        uint256 ma = bound(nMinA, 1, 6);
        uint256 mb = bound(nMinB, 1, 6);
        vm.assume(a != b || ma != mb);

        assertTrue(
            _rc(a, ma, seed) != _rc(b, mb, seed),
            "different array shapes produced the same commitment"
        );
    }

    /// POSITIVE (design confirmation) — the choice of `abi.encode` over
    /// `abi.encodePacked` is LOAD-BEARING, and binding amountOutMin made it
    /// MORE so: the 7-field preimage now runs
    ///     ... weightsBps | amountInWei | amountOutMin ...
    /// so a packed encoding would let one element migrate across TWO
    /// boundaries at once — drop the tail of weightsBps into amountInWei and
    /// push the old amountInWei onto the head of amountOutMin. Every field is
    /// 32-byte aligned when packed, so the byte string is identical:
    ///
    ///   A: w=[3000,7000] amountIn=1e18 min=[1,2]  -> 3000|7000|1e18|1|2
    ///   B: w=[3000]      amountIn=7000 min=[1e18,1,2] -> 3000|7000|1e18|1|2
    ///
    /// Both are semantically plausible orders. Under abi.encode they are
    /// distinct; under abi.encodePacked they are the SAME authorisation.
    /// This test fails the day someone "optimises" routeCommitment to packed.
    /// Shape A: w=[3000,7000] amountIn=1e18 min=[1,2]
    function _shapeA() internal view returns (bytes32 packed, bytes32 enc) {
        address[] memory t = new address[](1); t[0] = address(usdc);
        uint24[]  memory f = new uint24[](1);  f[0] = FEE;
        uint16[]  memory w = new uint16[](2);  w[0] = 3000; w[1] = 7000;
        uint256[] memory m = new uint256[](2); m[0] = 1; m[1] = 2;
        packed = keccak256(
            abi.encodePacked(block.chainid, address(vault), H0, agent, t, f, w, uint256(1e18), m, uint256(99))
        );
        enc = vault.routeCommitment(H0, agent, t, f, w, 1e18, m, 99);
    }

    /// Shape B: one element migrated across the amountInWei boundary —
    /// w=[3000] amountIn=7000 min=[1e18,1,2]
    function _shapeB() internal view returns (bytes32 packed, bytes32 enc) {
        address[] memory t = new address[](1); t[0] = address(usdc);
        uint24[]  memory f = new uint24[](1);  f[0] = FEE;
        uint16[]  memory w = new uint16[](1);  w[0] = 3000;
        uint256[] memory m = new uint256[](3); m[0] = 1e18; m[1] = 1; m[2] = 2;
        packed = keccak256(
            abi.encodePacked(block.chainid, address(vault), H0, agent, t, f, w, uint256(7000), m, uint256(99))
        );
        enc = vault.routeCommitment(H0, agent, t, f, w, 7000, m, 99);
    }

    function test_RT06d_EncodePackedWouldCollideAcrossTheNewAmountOutMinBoundary()
        public
        view
    {
        (bytes32 packedA, bytes32 encA) = _shapeA();
        (bytes32 packedB, bytes32 encB) = _shapeB();

        // packed: identical byte string -> identical hash (the hazard)
        assertEq(packedA, packedB, "encodePacked was expected to collide here");

        // abi.encode: length-prefixed and offset-based -> distinct
        assertTrue(encA != encB, "routeCommitment must NOT collide");
    }

    /// NEGATIVE — route and supply commitments share one `execCommitmentOf`
    /// slot but cannot be confused: their abi.encode preimages differ in length
    /// and shape, so an anchor minted for one executor is unusable at the other.
    function testFuzz_RT06e_RouteAndSupplyCommitmentsNeverCollide(uint256 amt, uint8 n)
        public
        view
    {
        uint256 len = bound(n, 1, 6);
        (address[] memory t, uint24[] memory f, uint16[] memory w) = _mk(len, amt);
        assertTrue(
            vault.routeCommitment(H0, agent, t, f, w, amt, _mkMin(len), FUTURE)
                != adapter.supplyCommitment(H0, agent, _market(), amt),
            "cross-executor commitment collision"
        );
    }

    function _mkMin(uint256 n) internal pure returns (uint256[] memory m) {
        m = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) m[i] = i + 1;
    }

    function _mk(uint256 n, uint256 seed)
        internal
        view
        returns (address[] memory t, uint24[] memory f, uint16[] memory w)
    {
        t = new address[](n); f = new uint24[](n); w = new uint16[](n);
        for (uint256 i = 0; i < n; ++i) {
            t[i] = uint256(keccak256(abi.encode(seed, i))) % 2 == 0
                ? address(usdc)
                : address(usdt);
            f[i] = FEE;
            w[i] = uint16(10_000 / n);
        }
    }

    // ============ PROBE 3: does consumption create a burn-on-failure DoS? ============

    /// NEGATIVE — `consumed` is written BEFORE the swaps, but a failure inside
    /// any leg reverts the whole transaction, so the flag rolls back with it.
    /// A partially-failed execution does NOT burn the anchor.
    ///
    /// Note the retry now has to reuse the IDENTICAL floor, because
    /// amountOutMin is part of the commitment — so this exercises the real
    /// post-M-7 recovery path: the order is retried unchanged once the
    /// ENVIRONMENT improves, not by quietly relaxing the floor.
    function test_RT06f_FailedExecutionDoesNotBurnTheAnchor() public {
        bytes32 h = keccak256("retry-me");
        address[] memory t = new address[](1); t[0] = address(usdc);
        uint24[]  memory f = new uint24[](1);  f[0] = FEE;
        uint16[]  memory w = new uint16[](1);  w[0] = 10_000;
        uint256[] memory m = new uint256[](1); m[0] = 2500 ether;  // above the 2000 rate
        _anchorRoute(agent, h, t, f, w, 1 ether, m);

        // Attempt 1: the pool cannot fill the anchored floor.
        vm.prank(agent);
        vm.expectRevert(bytes("Too little received"));
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE);

        assertFalse(vault.consumed(agent, h), "anchor NOT burned by the failed attempt");

        // Attempt 2: price improves; the SAME anchored order now fills.
        router.setRate(3000, 1);
        vm.prank(agent);
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE);
        assertTrue(vault.consumed(agent, h), "anchor consumed only on success");
        assertEq(usdc.balanceOf(agent), 3000 ether);
    }

    /// POSITIVE (Low, NEW) — the flip side of `AlreadyAnchored`: an anchor is
    /// immutable, so an agent that anchors a WRONG commitment for an orderHash
    /// has permanently bricked that orderHash for that address. There is no
    /// correction path — re-anchoring reverts, and every execution attempt
    /// reverts ExecutionNotAnchored forever. Recovery requires re-signing a new
    /// order off-chain (new orderHash), and the botched anchor still burned a
    /// sequence number in the audit chain.
    function test_RT06g_MiscommittedAnchorPermanentlyBricksThatOrderHash() public {
        bytes32 h = keccak256("fat-fingered");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _one(address(usdc));

        // agent commits to 2 ether but will fund the call with 1 ether
        _anchorRoute(agent, h, t, f, w, 2 ether, m);

        vm.prank(agent);
        vm.expectRevert();
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, FUTURE);

        // Cannot repair the anchor.
        bytes32 corrected = vault.routeCommitment(h, agent, t, f, w, 1 ether, m, FUTURE);
        uint64 seq = anchor.nextSequence(agent);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AuditAnchorV2.AlreadyAnchored.selector, h));
        anchor.anchor(h, corrected, seq);

        // The orderHash is dead for this address, and a sequence was consumed.
        assertEq(anchor.nextSequence(agent), 1, "botched anchor still burned a sequence");
    }

    // ====== NEW FINDING: the commitment does not cover amountOutMin/deadline ======

    /// INVERTED (finding M-7, now FIXED) — this is the exploit that motivated
    /// the 7-field commitment, re-run against the fix.
    ///
    /// ORIGINAL EXPLOIT: `routeCommitment` covered only
    /// (user, tokenOuts, feeTiers, weightsBps, amountInWei). `amountOutMin`
    /// and `deadline` — precisely the two parameters that determine economic
    /// loss — were left to whoever held the ECDSA key at submission time. An
    /// order whose PQ-signed intent was "floor 1900 USDC, valid 60 seconds"
    /// could be submitted with floor 1 and deadline type(uint256).max, 365
    /// days late, and the commitment still matched. That defeated the stated
    /// two-key custody property (src/monad_tx.py: the PQ key authorises the
    /// INTENT, the ECDSA key authorises the EXECUTION) and reduced the L-2
    /// zero-floor guard to a formality, since amountOutMin == 1 is
    /// economically identical to 0 on an 18-decimal token.
    ///
    /// Both fields are now in the preimage. This test targets what a
    /// single-leg scalar regression cannot reach: MULTI-LEG divergence, where
    /// only one element deep inside the amountOutMin array is altered, and
    /// order-sensitivity of that array.
    address[] internal _t3;
    uint24[]  internal _f3;
    uint16[]  internal _w3;

    function _setupThreeLegs() internal {
        _t3 = [address(usdc), address(usdt), address(usdc)];
        _f3 = [FEE, FEE, FEE];
        _w3 = [uint16(3000), uint16(3000), uint16(4000)];
    }

    /// Submit `m`/`deadline` against anchor `h` and require the vault to reject
    /// it as diverging from what was anchored. Own frame: keeps the IR stack
    /// under the limit.
    function _expectDivergent(bytes32 h, uint256[] memory m, uint256 deadline) internal {
        bytes32 anchored = anchor.execCommitmentOf(agent, h);
        bytes32 got = vault.routeCommitment(h, agent, _t3, _f3, _w3, 1 ether, m, deadline);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapRoutingVault.ExecutionNotAnchored.selector, got, anchored
            )
        );
        vault.executeAndRoute{ value: 1 ether }(h, _t3, _f3, _w3, m, deadline);
    }

    function _mins(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory m) {
        m = new uint256[](3); m[0] = a; m[1] = b; m[2] = c;
    }

    function test_RT06h_MultiLegFloorDivergenceIsRejected() public {
        _setupThreeLegs();
        bytes32 h = keccak256("intent");

        // PQ-signed intent: a real floor on every leg.
        uint256[] memory intended = _mins(570 ether, 570 ether, 760 ether);
        bytes32 c = vault.routeCommitment(h, agent, _t3, _f3, _w3, 1 ether, intended, FUTURE);
        uint64 seq = anchor.nextSequence(agent);
        vm.prank(agent);
        anchor.anchor(h, c, seq);

        // (1) gut ONE middle leg's floor to the legal minimum, leave the rest
        //     untouched. A scalar single-leg check would not catch this.
        _expectDivergent(h, _mins(570 ether, 1, 760 ether), FUTURE);

        // (2) PERMUTE the floors across legs — same multiset, different
        //     assignment, so a sum- or set-based check would pass it.
        _expectDivergent(h, _mins(760 ether, 570 ether, 570 ether), FUTURE);

        // (3) the original single-shot exploit: floor gutted AND deadline
        //     extended, executed 365 days past the signed deadline.
        vm.warp(block.timestamp + 365 days);
        _expectDivergent(h, _mins(1, 1, 1), type(uint256).max);

        assertFalse(vault.consumed(agent, h), "nothing executed");
        assertEq(usdc.balanceOf(agent), 0);
        assertEq(usdt.balanceOf(agent), 0);
    }

    /// Same gap on the adapter side is NARROWER but present: `supplyCommitment`
    /// binds the market and the ceiling, so the realised `assets` may be any
    /// value in (0, maxAssets]. That is deliberate per the NatSpec (the yield
    /// leg chains off an unknown swap output), but it does mean an anchor for
    /// "up to 1000 USDC" also authorises supplying 1 wei.
    function test_RT06i_SupplyCommitmentBindsOnlyTheCeiling() public {
        bytes32 h = keccak256("supply-intent");
        _anchorSupply(agent, h, 1000 ether);

        vm.startPrank(agent);
        usdc.faucet(1000 ether);
        usdc.approve(address(adapter), type(uint256).max);
        adapter.supply(h, _market(), 1, 1000 ether);   // 1 wei against a 1000e18 ceiling
        vm.stopPrank();

        assertTrue(adapter.consumed(agent, h), "anchor spent on a 1-wei supply");
    }

    function _anchorSupply(address who, bytes32 h, uint256 maxAssets) internal {
        bytes32 c = adapter.supplyCommitment(h, who, _market(), maxAssets);
        uint64 _seq = anchor.nextSequence(who);
        vm.prank(who);
        anchor.anchor(h, c, _seq);
    }
}
