// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test }   from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { WMON }        from "../../src/dex/WMON.sol";
import { MockToken }   from "../../src/dex/MockToken.sol";
import { AuditAnchorV2 } from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { FaithfulRouter }      from "./RT03_DustInvariantAttacks.t.sol";

/// RED TEAM — RT-05: the `remaining` accumulator / weightsBps arithmetic.
/// All results here are NEGATIVE (the accounting is sound); recorded so the
/// "integer issues" category is evidenced rather than merely asserted.
contract RT05_WeightAccounting is Test {
    WMON wmon;
    MockToken usdc;
    AuditAnchorV2 anchor;
    FaithfulRouter router;
    UniswapRoutingVault vault;

    address alice = address(0xA11CE);
    uint24 constant FEE = 3000;
    uint256 constant FUTURE = 1e18;

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("USDC", "USDC", 18);
        anchor = new AuditAnchorV2();
        router = new FaithfulRouter();

        address[] memory approved = new address[](1);
        approved[0] = address(usdc);
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = FEE;
        vault = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), approved, tiers
        );

        for (uint256 i = 0; i < 50; ++i) {
            usdc.faucet(100_000 ether);
            usdc.transfer(address(router), 100_000 ether);
        }
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
        bytes32 c = vault.routeCommitment(who, t, f, w, amountInWei, m, FUTURE);
        uint64 _seq = anchor.nextSequence(who);
        vm.prank(who);
        anchor.anchor(h, c, _seq);
    }

    /// NEGATIVE — for ANY 3-way split summing to 10_000 with no zero legs, and
    /// any deposit, `remaining` never underflows and exactly msg.value is
    /// deployed (the last leg absorbs the floor remainder, <= n-1 wei).
    function testFuzz_RT05a_RemainingAccumulatorNeverUnderflows(
        uint96 amount,
        uint16 w0,
        uint16 w1
    ) public {
        amount = uint96(bound(amount, 1e6, 1_000 ether));
        w0 = uint16(bound(w0, 1, 9_998));
        w1 = uint16(bound(w1, 1, 9_999 - w0));
        uint16 w2 = uint16(10_000 - w0 - w1);
        vm.assume(w2 > 0);

        vm.deal(alice, amount);
        bytes32 h = keccak256("fuzz");

        address[] memory t = new address[](3);
        uint24[]  memory f = new uint24[](3);
        uint16[]  memory w = new uint16[](3);
        uint256[] memory m = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) { t[i] = address(usdc); f[i] = FEE; m[i] = 1; }
        w[0] = w0; w[1] = w1; w[2] = w2;

        uint256 routerWmonBefore = wmon.balanceOf(address(router));

        _anchorRoute(alice, h, t, f, w, amount, m);
        vm.prank(alice);
        vault.executeAndRoute{ value: amount }(h, t, f, w, m, FUTURE);

        // Every wei of the deposit reached the router; nothing stranded.
        assertEq(wmon.balanceOf(address(router)) - routerWmonBefore, amount, "full deposit routed");
        assertEq(wmon.balanceOf(address(vault)), 0, "vault holds nothing");
        assertEq(address(vault).balance, 0, "vault holds no native MON");
    }

    /// NEGATIVE — n == 1 degenerate case: the single leg IS the last leg, so it
    /// takes `remaining` (== msg.value) and the weight is only sum-checked.
    function test_RT05b_SingleLegTakesEntireDeposit() public {
        vm.deal(alice, 3 ether);
        bytes32 h = keccak256("n1");
        address[] memory t = new address[](1); t[0] = address(usdc);
        uint24[]  memory f = new uint24[](1);  f[0] = FEE;
        uint16[]  memory w = new uint16[](1);  w[0] = 10_000;
        uint256[] memory m = new uint256[](1); m[0] = 1;

        _anchorRoute(alice, h, t, f, w, 3 ether, m);
        vm.prank(alice);
        vault.executeAndRoute{ value: 3 ether }(h, t, f, w, m, FUTURE);
        assertEq(usdc.balanceOf(alice), 3 ether * 2000);
    }

    /// NEGATIVE — a large n is a caller-funded gas cost, not a griefing vector:
    /// no other user's call is affected and the caller pays for their own legs.
    function test_RT05c_LargeNIsCallerFundedOnly() public {
        uint256 n = 300;
        vm.deal(alice, 100 ether);
        bytes32 h = keccak256("bign");

        address[] memory t = new address[](n);
        uint24[]  memory f = new uint24[](n);
        uint16[]  memory w = new uint16[](n);
        uint256[] memory m = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            t[i] = address(usdc); f[i] = FEE; m[i] = 1;
            w[i] = i == n - 1 ? uint16(10_000 - 33 * (n - 1)) : 33;
        }

        _anchorRoute(alice, h, t, f, w, 100 ether, m);
        vm.prank(alice);
        uint256 g = gasleft();
        vault.executeAndRoute{ value: 100 ether }(h, t, f, w, m, FUTURE);
        emit log_named_uint("gas for 300 legs", g - gasleft());
        assertEq(wmon.balanceOf(address(vault)), 0);
    }

    /// NEGATIVE — AuditAnchor's `unchecked { sequence + 1 }` on a uint64 needs
    /// 2**64 anchors to wrap. Prove the counter is only reachable one call at a
    /// time (no batch/self-increment path) so the overflow is not attackable.
    function test_RT05d_SequenceAdvancesOnlyOnePerCall() public {
        vm.startPrank(alice);
        for (uint64 i = 0; i < 5; ++i) {
            assertEq(anchor.nextSequence(alice), i);
            anchor.anchor(keccak256(abi.encode(i)), keccak256(abi.encode("c", i)), i);
        }
        assertEq(anchor.nextSequence(alice), 5);
        vm.stopPrank();
    }
}
