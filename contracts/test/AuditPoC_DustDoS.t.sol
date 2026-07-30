// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 }    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { WMON }       from "../src/dex/WMON.sol";
import { MockToken }  from "../src/dex/MockToken.sol";
import { AuditAnchorV2 } from "../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../src/UniswapRoutingVault.sol";
import { MorphoSupplyAdapter } from "../src/MorphoSupplyAdapter.sol";
import { MarketParams }        from "../src/interfaces/IMorpho.sol";
import { IV3SwapRouter }       from "../src/interfaces/IV3SwapRouter.sol";
import { MockV3SwapRouter }    from "./mocks/MockV3SwapRouter.sol";

/// Minimal Morpho stand-in: pulls the exact assets and credits shares 1:1.
contract MockMorpho {
    function supply(MarketParams calldata params, uint256 assets, uint256, address, bytes calldata)
        external
        returns (uint256, uint256)
    {
        MockToken(params.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, assets);
    }
}

/// Morpho stand-in that supplies LESS than it was handed — used to prove the
/// real "everything pulled was deployed" invariant still fires after the fix.
contract UnderConsumingMorpho {
    function supply(MarketParams calldata params, uint256 assets, uint256, address, bytes calldata)
        external
        returns (uint256, uint256)
    {
        uint256 taken = assets - 1;                 // strand 1 unit in the adapter
        MockToken(params.loanToken).transferFrom(msg.sender, address(this), taken);
        return (taken, taken);
    }
}

/// Router stand-in that tries to pull MORE tokenIn than `amountIn` — used to
/// prove that tolerating donated dust does NOT make that dust stealable.
contract GreedyRouter is IV3SwapRouter {
    using SafeERC20 for IERC20;

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        // Attempt to sweep the vault's entire balance, dust included.
        uint256 grab = IERC20(p.tokenIn).balanceOf(msg.sender);
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), grab);
        amountOut = grab * 2000;
        IERC20(p.tokenOut).safeTransfer(p.recipient, amountOut);
    }
}

/// Morpho stand-in that tries to pull MORE than `assets` — same purpose.
contract GreedyMorpho {
    function supply(MarketParams calldata params, uint256 assets, uint256, address, bytes calldata)
        external
        returns (uint256, uint256)
    {
        uint256 grab = MockToken(params.loanToken).balanceOf(msg.sender);
        MockToken(params.loanToken).transferFrom(msg.sender, address(this), grab);
        return (grab, grab);
    }
}

/// Router stand-in that pulls LESS tokenIn than `amountIn` — used to prove the
/// vault's real invariant (full deposit routed) still fires after the fix.
contract UnderConsumingRouter is IV3SwapRouter {
    using SafeERC20 for IERC20;

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        uint256 pulled = p.amountIn - 1;            // strand 1 wei in the vault
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), pulled);
        amountOut = pulled * 2000;
        IERC20(p.tokenOut).safeTransfer(p.recipient, amountOut);
    }
}

/// Regression suite for audit findings H-1 / H-2 (2026-07-28).
///
/// BEFORE THE FIX: `UniswapRoutingVault` and `MorphoSupplyAdapter` asserted
/// `balanceOf(address(this)) == 0` after routing. Neither holds funds between
/// calls and neither has a rescue path, so an unsolicited 1-wei token donation
/// bricked every future call permanently.
///
/// AFTER THE FIX: the invariant is asserted relative to the balance on entry,
/// so donated dust is inert — while the property that actually mattered (the
/// full deposit was deployed) still holds. Both are covered below.
contract AuditPoCDustDoSTest is Test {
    WMON wmon;
    MockToken usdc;
    AuditAnchorV2 anchor;
    MockV3SwapRouter router;
    UniswapRoutingVault vault;
    MockMorpho morpho;
    MorphoSupplyAdapter adapter;

    address alice     = address(0xA11CE);
    address attacker  = address(0xBAD);

    uint24  constant FEE    = 3000;
    uint256 constant FUTURE = 1e18;
    bytes32 constant ORDER  = keccak256("order-1");
    bytes32 constant ORDER2 = keccak256("order-2");

    function setUp() public {
        wmon   = new WMON();
        usdc   = new MockToken("Test USDC", "mUSDC", 18);
        anchor = new AuditAnchorV2();
        router = new MockV3SwapRouter();
        morpho = new MockMorpho();

        address[] memory approved = new address[](1);
        approved[0] = address(usdc);

        uint24[] memory fees = new uint24[](1); fees[0] = FEE;
        vault   = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), approved, fees
        );
        adapter = new MorphoSupplyAdapter(
            address(morpho), address(anchor), approved, _markets(address(usdc))
        );

        router.setRate(2000, 1);
        usdc.faucet(100_000 ether);
        usdc.transfer(address(router), 50_000 ether);

        vm.deal(alice, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    function _oneLeg()
        internal
        view
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](1); t[0] = address(usdc);
        f = new uint24[](1);  f[0] = FEE;
        w = new uint16[](1);  w[0] = 10_000;
        m = new uint256[](1); m[0] = 1;
    }

    function _params(address loan) internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken:       loan,
            collateralToken: address(0xC0113),
            oracle:          address(0x0AC1E),
            irm:             address(0x121212),
            lltv:            860000000000000000
        });
    }

    function _anchorRoute(
        UniswapRoutingVault v, address who, bytes32 oh,
        address[] memory t, uint24[] memory f, uint16[] memory w, uint256 amt,
        uint256[] memory m
    ) internal {
        bytes32 c = v.routeCommitment(oh, who, t, f, w, amt, m, FUTURE);
        uint64  q = anchor.nextSequence(who);
        vm.prank(who);
        anchor.anchor(oh, c, q);
    }

    function _anchorSupply(
        MorphoSupplyAdapter a, address who, bytes32 oh, address loan, uint256 maxA
    ) internal {
        bytes32 c = a.supplyCommitment(oh, who, _params(loan), maxA);
        uint64  q = anchor.nextSequence(who);
        vm.prank(who);
        anchor.anchor(oh, c, q);
    }

    function _markets(address loan) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = keccak256(abi.encode(_params(loan)));
    }

    // --- H-1: vault -------------------------------------------------------

    /// Baseline: the vault works with no dust present.
    function test_VaultWorksWithNoDust() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _oneLeg();
        _anchorRoute(vault, alice, ORDER, t, f, w, 1 ether, m);
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(ORDER, t, f, w, m, FUTURE);
        assertGt(usdc.balanceOf(alice), 0, "alice should have received USDC");
    }

    /// H-1 REGRESSION: a 1-wei WMON donation must NOT brick the vault.
    function test_H1_DonatedWMonDustDoesNotBrickVault() public {
        vm.startPrank(attacker);
        wmon.deposit{value: 1}();
        wmon.transfer(address(vault), 1);
        vm.stopPrank();
        assertEq(wmon.balanceOf(address(vault)), 1, "vault holds donated dust");

        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _oneLeg();

        // First order succeeds despite the dust.
        _anchorRoute(vault, alice, ORDER, t, f, w, 1 ether, m);
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(ORDER, t, f, w, m, FUTURE);
        assertGt(usdc.balanceOf(alice), 0, "alice received USDC");

        // And a second, independent order also succeeds — not a one-off.
        uint256 balMid = usdc.balanceOf(alice);
        _anchorRoute(vault, alice, ORDER2, t, f, w, 1 ether, m);
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(ORDER2, t, f, w, m, FUTURE);
        assertGt(usdc.balanceOf(alice), balMid, "second order also routed");

        // The donated dust is inert: still exactly 1 wei, never touched.
        assertEq(wmon.balanceOf(address(vault)), 1, "dust untouched");
    }

    /// Larger donations are equally inert.
    function testFuzz_H1_AnyDonationAmountIsInert(uint96 donation) public {
        donation = uint96(bound(uint256(donation), 1, 5 ether));
        vm.startPrank(attacker);
        vm.deal(attacker, uint256(donation) + 1 ether);
        wmon.deposit{value: donation}();
        wmon.transfer(address(vault), donation);
        vm.stopPrank();

        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _oneLeg();
        _anchorRoute(vault, alice, ORDER, t, f, w, 1 ether, m);
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(ORDER, t, f, w, m, FUTURE);

        assertEq(wmon.balanceOf(address(vault)), donation, "donation untouched");
        assertGt(usdc.balanceOf(alice), 0, "route succeeded");
    }

    /// The REAL invariant must still fire: if the router leaves part of the
    /// deposit behind, the call reverts even though dust is now tolerated.
    function test_H1_UnroutedDepositStillReverts() public {
        UnderConsumingRouter badRouter = new UnderConsumingRouter();
        address[] memory approved = new address[](1);
        approved[0] = address(usdc);
        uint24[] memory fees = new uint24[](1); fees[0] = FEE;
        UniswapRoutingVault v2 = new UniswapRoutingVault(
            address(wmon), address(badRouter), address(anchor), approved, fees
        );
        usdc.transfer(address(badRouter), 50_000 ether);

        // Pre-existing donated dust, to prove the check measures the DELTA.
        vm.startPrank(attacker);
        wmon.deposit{value: 7}();
        wmon.transfer(address(v2), 7);
        vm.stopPrank();

        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _oneLeg();
        _anchorRoute(v2, alice, ORDER, t, f, w, 1 ether, m);
        vm.prank(alice);
        // 1 wei of the deposit is stranded -> delta is 1, not 8.
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingVault.WMonDustResidual.selector, 1));
        v2.executeAndRoute{value: 1 ether}(ORDER, t, f, w, m, FUTURE);
    }

    /// NEW-RISK CHECK for the H-1 fix: tolerating dust must not make it
    /// stealable. The approval handed to the router is exactly `msg.value`,
    /// so a counterparty that tries to sweep the contract's whole balance
    /// exceeds its allowance and the call reverts — dust is unreachable.
    function test_H1Fix_DonatedDustIsNotStealableByGreedyRouter() public {
        GreedyRouter greedy = new GreedyRouter();
        address[] memory approved = new address[](1);
        approved[0] = address(usdc);
        uint24[] memory fees = new uint24[](1); fees[0] = FEE;
        UniswapRoutingVault v2 = new UniswapRoutingVault(
            address(wmon), address(greedy), address(anchor), approved, fees
        );
        usdc.transfer(address(greedy), 50_000 ether);

        vm.startPrank(attacker);
        wmon.deposit{value: 3 ether}();
        wmon.transfer(address(v2), 3 ether);
        vm.stopPrank();

        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _oneLeg();
        _anchorRoute(v2, alice, ORDER, t, f, w, 1 ether, m);
        vm.prank(alice);
        vm.expectRevert();  // ERC20 allowance exceeded
        v2.executeAndRoute{value: 1 ether}(ORDER, t, f, w, m, FUTURE);

        // Dust survives untouched.
        assertEq(wmon.balanceOf(address(v2)), 3 ether, "dust not stolen");
    }

    // --- H-2: Morpho adapter ---------------------------------------------

    /// H-2 REGRESSION: a 1-unit loan-token donation must NOT brick the adapter.
    function test_H2_DonatedTokenDustDoesNotBrickAdapter() public {
        usdc.transfer(alice, 1_000 ether);
        vm.prank(alice);
        usdc.approve(address(adapter), type(uint256).max);

        usdc.transfer(address(adapter), 1);
        assertEq(usdc.balanceOf(address(adapter)), 1, "adapter holds donated dust");

        _anchorSupply(adapter, alice, ORDER, address(usdc), 100 ether);
        vm.prank(alice);
        uint256 shares = adapter.supply(ORDER, _params(address(usdc)), 100 ether, 100 ether);
        assertEq(shares, 100 ether, "supply credited");

        // Second supply also works; dust still inert.
        _anchorSupply(adapter, alice, ORDER2, address(usdc), 50 ether);
        vm.prank(alice);
        adapter.supply(ORDER2, _params(address(usdc)), 50 ether, 50 ether);
        assertEq(usdc.balanceOf(address(adapter)), 1, "dust untouched");
    }

    /// NEW-RISK CHECK for the H-2 fix: same question for the adapter. The
    /// allowance granted to Morpho is exactly `assets`, so a greedy
    /// counterparty cannot reach the donated dust.
    function test_H2Fix_DonatedDustIsNotStealableByGreedyMorpho() public {
        GreedyMorpho greedy = new GreedyMorpho();
        address[] memory approved = new address[](1);
        approved[0] = address(usdc);
        MorphoSupplyAdapter a2 = new MorphoSupplyAdapter(
            address(greedy), address(anchor), approved, _markets(address(usdc))
        );

        usdc.transfer(alice, 1_000 ether);
        vm.prank(alice);
        usdc.approve(address(a2), type(uint256).max);

        usdc.transfer(address(a2), 500 ether);   // sizeable donation

        _anchorSupply(a2, alice, ORDER, address(usdc), 100 ether);
        vm.prank(alice);
        vm.expectRevert();  // ERC20 allowance exceeded
        a2.supply(ORDER, _params(address(usdc)), 100 ether, 100 ether);

        assertEq(usdc.balanceOf(address(a2)), 500 ether, "dust not stolen");
    }

    /// The REAL invariant must still fire for the adapter too.
    function test_H2_UnsuppliedAssetsStillRevert() public {
        UnderConsumingMorpho badMorpho = new UnderConsumingMorpho();
        address[] memory approved = new address[](1);
        approved[0] = address(usdc);
        MorphoSupplyAdapter a2 = new MorphoSupplyAdapter(
            address(badMorpho), address(anchor), approved, _markets(address(usdc))
        );

        usdc.transfer(alice, 1_000 ether);
        vm.prank(alice);
        usdc.approve(address(a2), type(uint256).max);

        // Pre-existing donated dust, to prove the check measures the DELTA.
        usdc.transfer(address(a2), 9);

        _anchorSupply(a2, alice, ORDER, address(usdc), 100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MorphoSupplyAdapter.DustResidual.selector, 1));
        a2.supply(ORDER, _params(address(usdc)), 100 ether, 100 ether);
    }
}
