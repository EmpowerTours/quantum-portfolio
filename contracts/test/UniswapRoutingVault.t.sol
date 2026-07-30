// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm }   from "forge-std/Vm.sol";
import { WMON }      from "../src/dex/WMON.sol";
import { MockToken } from "../src/dex/MockToken.sol";
import { AuditAnchorV2 } from "../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../src/UniswapRoutingVault.sol";
import { MockV3SwapRouter }    from "./mocks/MockV3SwapRouter.sol";

contract UniswapRoutingVaultTest is Test {
    WMON wmon;
    MockToken usdc;
    MockToken usdt;
    AuditAnchorV2 anchor;
    MockV3SwapRouter router;
    UniswapRoutingVault vault;

    address alice = address(0xA11CE);

    uint24 constant FEE = 3000;
    uint256 constant FUTURE = 1e18; // deadline far in the future

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("Test USDC", "mUSDC", 18);
        usdt = new MockToken("Test USDT", "mUSDT", 18);
        anchor = new AuditAnchorV2();
        router = new MockV3SwapRouter();

        address[] memory approved = new address[](2);
        approved[0] = address(usdc);
        approved[1] = address(usdt);
        uint24[] memory fees = new uint24[](1);
        fees[0] = FEE;
        vault = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), approved, fees
        );

        // Rate: 1 WMON -> 2000 tokenOut (18-dec test tokens).
        router.setRate(2000, 1);
        // Fund the router's output inventory (faucet caps at 100k/call).
        usdc.faucet(100_000 ether);
        usdt.faucet(100_000 ether);
        usdc.transfer(address(router), 100_000 ether);
        usdt.transfer(address(router), 100_000 ether);

        vm.deal(alice, 10 ether);
    }

    /// Anchor `orderHash` bound to exactly the execution that follows.
    function _anchorFor(
        address who,
        bytes32 orderHash,
        address[] memory t,
        uint24[] memory f,
        uint16[] memory w,
        uint256 amountInWei,
        uint256[] memory m,
        uint256 deadline
    ) internal {
        // Evaluate BOTH external reads before pranking: vm.prank applies to the
        // next external call, which would otherwise be routeCommitment().
        bytes32 commitment = vault.routeCommitment(orderHash, who, t, f, w, amountInWei, m, deadline);
        uint64  seq        = anchor.nextSequence(who);
        vm.prank(who);
        anchor.anchor(orderHash, commitment, seq);
    }

    function _twoLeg()
        internal
        view
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](2); t[0] = address(usdc); t[1] = address(usdt);
        f = new uint24[](2);  f[0] = FEE;           f[1] = FEE;
        w = new uint16[](2);  w[0] = 5000;          w[1] = 5000;
        m = new uint256[](2); m[0] = 900 ether;     m[1] = 900 ether;
    }

    function _oneLeg(address tokenOut, uint16 weight, uint256 minOut)
        internal
        pure
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](1); t[0] = tokenOut;
        f = new uint24[](1);  f[0] = FEE;
        w = new uint16[](1);  w[0] = weight;
        m = new uint256[](1); m[0] = minOut;
    }

    // --- happy paths ------------------------------------------------------

    /// Happy path: 1 MON split 50/50, real router returns MORE than the
    /// caller's minimum (H-1 fix — surplus flows to the user, not LPs).
    function test_HappyPathDeliversAboveMin() public {
        bytes32 orderHash = keccak256("happy");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);

        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);

        assertEq(usdc.balanceOf(alice), 1000 ether, "usdc out");
        assertEq(usdt.balanceOf(alice), 1000 ether, "usdt out");
        assertGt(usdc.balanceOf(alice), m[0], "user must receive MORE than the minimum");
        assertEq(wmon.balanceOf(address(vault)), 0, "vault WMON dust");
        assertEq(
            wmon.allowance(address(vault), address(router)), 0, "router approval not reset"
        );
    }

    /// Odd-value split: last leg absorbs the remainder, whole deposit spent.
    function test_RemainderGoesToLastLeg() public {
        bytes32 orderHash = keccak256("remainder");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        w[0] = 3333; w[1] = 6667;
        m[0] = 1; m[1] = 1;

        uint256 odd = 1 ether + 1; // not divisible cleanly by 10_000
        _anchorFor(alice, orderHash, t, f, w, odd, m, FUTURE);
        vm.prank(alice);
        vault.executeAndRoute{value: odd}(orderHash, t, f, w, m, FUTURE);

        assertEq(wmon.balanceOf(address(vault)), 0, "vault must retain no WMON");
        assertEq(usdc.balanceOf(alice) + usdt.balanceOf(alice), odd * 2000, "total out");
    }

    // --- M-6: execution binding + single use ------------------------------

    /// Binding: the anchor commits to specific parameters; executing DIFFERENT
    /// parameters under the same orderHash must revert.
    function test_M6_RevertsWhenExecutionDivergesFromAnchor() public {
        bytes32 orderHash = keccak256("diverge");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);

        // Same order hash, but flip the weights -> different commitment.
        w[0] = 9000; w[1] = 1000;
        bytes32 divergent = vault.routeCommitment(orderHash, alice, t, f, w, 1 ether, m, FUTURE);
        bytes32 recorded  = anchor.execCommitmentOf(alice, orderHash);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapRoutingVault.ExecutionNotAnchored.selector, divergent, recorded
            )
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    /// Binding covers msg.value too: same allocation, different size, rejected.
    function test_M6_RevertsWhenValueDivergesFromAnchor() public {
        bytes32 orderHash = keccak256("value-diverge");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);

        vm.prank(alice);
        vm.expectRevert();
        vault.executeAndRoute{value: 2 ether}(orderHash, t, f, w, m, FUTURE);
    }

    /// M-7: the commitment must cover `amountOutMin`. Anchoring an intent with
    /// a real slippage floor and then submitting a floor of 1 is exactly how a
    /// compromised broadcaster deviates from PQ-signed intent while still
    /// producing a correctly-anchored trade.
    function test_M7_RevertsWhenSlippageFloorDivergesFromAnchor() public {
        bytes32 orderHash = keccak256("floor-diverge");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);

        // Signed intent said 900 ether per leg; broadcaster tries to drop it to 1.
        m[0] = 1; m[1] = 1;
        vm.prank(alice);
        vm.expectRevert();
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    /// M-7: the commitment must cover `deadline`, so an expired order cannot be
    /// replayed later under a fresh deadline.
    function test_M7_RevertsWhenDeadlineDivergesFromAnchor() public {
        bytes32 orderHash = keccak256("deadline-diverge");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);

        vm.prank(alice);
        vm.expectRevert();
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, type(uint256).max);
    }

    /// Single use: one anchor authorises exactly one execution.
    function test_M6_RevertsOnReplayOfSameAnchor() public {
        bytes32 orderHash = keccak256("replay");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);

        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);

        // Re-anchoring the same hash is refused by the anchor itself...
        bytes32 c = vault.routeCommitment(orderHash, alice, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AuditAnchorV2.AlreadyAnchored.selector, orderHash)
        );
        anchor.anchor(orderHash, c, 1);

        // ...and the vault refuses a second execution regardless.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapRoutingVault.AnchorAlreadyConsumed.selector, orderHash
            )
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    /// L-1: anchoring the NEXT order must not strand an in-flight earlier one.
    function test_L1_PipeliningDoesNotStrandEarlierOrder() public {
        bytes32 orderN  = keccak256("order-N");
        bytes32 orderN1 = keccak256("order-N+1");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();

        _anchorFor(alice, orderN,  t, f, w, 1 ether, m, FUTURE);
        _anchorFor(alice, orderN1, t, f, w, 1 ether, m, FUTURE);

        // Order N still executes even though N+1 was anchored after it.
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderN, t, f, w, m, FUTURE);
        assertGt(usdc.balanceOf(alice), 0, "order N must still be executable");

        // And N+1 executes independently.
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderN1, t, f, w, m, FUTURE);
    }

    // --- new per-leg guards ----------------------------------------------

    /// M-5: a zero-weight leg would floor amountIn to 0, which SwapRouter02
    /// reads as its CONTRACT_BALANCE sentinel. Rejected outright — by the
    /// semantic weight check (`ZeroWeightBps`), which now runs BEFORE the
    /// quantity check. See RT07h for why both are required.
    function test_M5_RevertsOnZeroWeightLeg() public {
        bytes32 orderHash = keccak256("zero-weight");
        address[] memory t = new address[](2);
        t[0] = address(usdc); t[1] = address(usdt);
        uint24[] memory f = new uint24[](2);  f[0] = FEE;  f[1] = FEE;
        uint16[] memory w = new uint16[](2);  w[0] = 0;    w[1] = 10_000;
        uint256[] memory m = new uint256[](2); m[0] = 1;   m[1] = 1;

        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingVault.ZeroWeightBps.selector, 0));
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    /// H-3: fee tiers select the POOL; unapproved tiers can be near-empty.
    function test_H3_RevertsOnUnapprovedFeeTier() public {
        bytes32 orderHash = keccak256("bad-fee");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 1);
        f[0] = 100; // dust pool tier, not allowlisted
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.FeeTierNotApproved.selector, 0, uint24(100))
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    /// L-2: an unbounded slippage floor is fail-open on a thin pool.
    function test_L2_RevertsOnZeroSlippageFloor() public {
        bytes32 orderHash = keccak256("zero-min");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 0);
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.ZeroSlippageFloor.selector, 0)
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    // --- pre-existing guards ---------------------------------------------

    function test_RevertsOnZeroValue() public {
        bytes32 orderHash = keccak256("zv");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 1);
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(UniswapRoutingVault.ZeroValue.selector);
        vault.executeAndRoute{value: 0}(orderHash, t, f, w, m, FUTURE);
    }

    function test_RevertsOnZeroHash() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 1);
        vm.prank(alice);
        vm.expectRevert(UniswapRoutingVault.ZeroHash.selector);
        vault.executeAndRoute{value: 1 ether}(bytes32(0), t, f, w, m, FUTURE);
    }

    function test_RevertsOnPastDeadline() public {
        bytes32 orderHash = keccak256("deadline");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 1);
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);
        vm.warp(1_000_000);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.DeadlinePassed.selector, 999_999, 1_000_000)
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, 999_999);
    }

    function test_RevertsWithoutAnchor() public {
        bytes32 orderHash = keccak256("never-anchored");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.AnchorNotFound.selector, orderHash)
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    function test_RevertsOnUnapprovedToken() public {
        bytes32 orderHash = keccak256("bad-token");
        MockToken rogue = new MockToken("Rogue", "RG", 18);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(rogue), 10_000, 1);
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.TokenNotApproved.selector, 0, address(rogue))
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    function test_RevertsOnWeightsNotSumming() public {
        bytes32 orderHash = keccak256("weights");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 9999, 1);
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.WeightsDoNotSumTo10000.selector, 9999)
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    function test_RevertsOnLengthMismatch() public {
        bytes32 orderHash = keccak256("len");
        address[] memory t = new address[](2);
        t[0] = address(usdc); t[1] = address(usdt);
        uint24[] memory f = new uint24[](1); f[0] = FEE;   // mismatched
        uint16[] memory w = new uint16[](2); w[0] = 5000; w[1] = 5000;
        uint256[] memory m = new uint256[](2); m[0] = 1; m[1] = 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingVault.LengthMismatch.selector, 2));
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    /// Slippage floor: if the router can't meet amountOutMin the whole
    /// routine reverts (the router's TooLittleReceived bubbles up).
    function test_RevertsOnExcessiveSlippage() public {
        bytes32 orderHash = keccak256("slip");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 999_999 ether); // impossible min
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert();
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    function test_RevertsOnNakedSend() public {
        vm.prank(alice);
        vm.expectRevert(UniswapRoutingVault.ZeroHash.selector);
        (bool ok, ) = address(vault).call{value: 1 ether}("");
        ok;
    }

    function test_RoutedEventCarriesOrderHash() public {
        bytes32 orderHash = keccak256("event");
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        _anchorFor(alice, orderHash, t, f, w, 1 ether, m, FUTURE);

        vm.recordLogs();
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);

        bytes32 expectedTopic = keccak256(
            "Routed(address,bytes32,uint256,address[],uint24[],uint256[],uint16[])"
        );
        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == expectedTopic) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(alice))));
                assertEq(logs[i].topics[2], orderHash);
                found = true;
                break;
            }
        }
        assertTrue(found, "Routed event with correct orderHash not emitted");
    }
}
