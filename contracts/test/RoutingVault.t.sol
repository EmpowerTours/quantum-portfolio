// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { WMON } from "../src/dex/WMON.sol";
import { MockToken } from "../src/dex/MockToken.sol";
import { MiniAMM } from "../src/dex/MiniAMM.sol";
import { RoutingVault } from "../src/RoutingVault.sol";
import { AuditAnchor } from "../src/AuditAnchor.sol";

contract RoutingVaultTest is Test {
    WMON wmon;
    MockToken usdc;
    MockToken usdt;
    MiniAMM pairWmonUsdc;
    MiniAMM pairWmonUsdt;
    RoutingVault vault;
    AuditAnchor anchor;

    address alice = address(0xA11CE);
    address lp    = address(0x11111);

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("Test USDC", "mUSDC", 18);
        usdt = new MockToken("Test USDT", "mUSDT", 18);
        pairWmonUsdc = new MiniAMM(address(wmon), address(usdc));
        pairWmonUsdt = new MiniAMM(address(wmon), address(usdt));
        anchor = new AuditAnchor();
        address[] memory approved = new address[](2);
        approved[0] = address(pairWmonUsdc);
        approved[1] = address(pairWmonUsdt);
        vault = new RoutingVault(payable(address(wmon)), address(anchor), approved);

        vm.deal(lp, 100 ether);
        usdc.faucet(50_000 ether);
        usdt.faucet(50_000 ether);
        usdc.transfer(lp, 50_000 ether);
        usdt.transfer(lp, 50_000 ether);

        vm.startPrank(lp);
        wmon.deposit{value: 20 ether}();
        _addLp(pairWmonUsdc, address(wmon), 10 ether, address(usdc), 25_000 ether);
        _addLp(pairWmonUsdt, address(wmon), 10 ether, address(usdt), 25_000 ether);
        vm.stopPrank();

        vm.deal(alice, 10 ether);
    }

    function _addLp(MiniAMM pair, address tA, uint256 amtA, address tB, uint256 amtB) internal {
        wmon.approve(address(pair), type(uint256).max);
        usdc.approve(address(pair), type(uint256).max);
        usdt.approve(address(pair), type(uint256).max);
        (uint256 amount0, uint256 amount1) = tA < tB ? (amtA, amtB) : (amtB, amtA);
        pair.addLiquidity(amount0, amount1, lp);
    }

    /// Helper: anchor `orderHash` as `who` on AuditAnchor. Required before
    /// executeAndRoute will accept the same orderHash from the same caller.
    function _anchor(address who, bytes32 orderHash) internal {
        vm.prank(who);
        anchor.anchor(orderHash);
    }

    /// Compute the amount of `tokenOut` that 0.5 * amountIn would yield
    /// through `pair`, applying a small downward slippage tolerance so
    /// amountOutMin is achievable even with rounding noise. Mirrors how
    /// the off-chain agent would build minOuts before signing.
    function _quoteSwap(MiniAMM pair, uint256 amountIn) internal view returns (uint256) {
        bool wmonIsT0 = address(pair.token0()) == address(wmon);
        return wmonIsT0
            ? pair.quoteToken1Out(amountIn)
            : pair.quoteToken0Out(amountIn);
    }

    // -----------------------------------------------------------------

    /// Happy path: alice anchors, then deposits 1 MON, vault splits 50/50,
    /// swaps each leg with caller-supplied amountOutMin, alice receives
    /// (at least) the requested tokens. Vault holds no WMON residual.
    function test_ExecuteAndRouteHappyPath() public {
        bytes32 orderHash = keccak256("happy-order");
        _anchor(alice, orderHash);

        uint256 halfMon = 0.5 ether;
        uint256 minOutUsdc = _quoteSwap(pairWmonUsdc, halfMon) * 99 / 100; // 1% slippage tolerance
        uint256 minOutUsdt = _quoteSwap(pairWmonUsdt, halfMon) * 99 / 100;

        address[] memory tokenOuts = new address[](2);
        tokenOuts[0] = address(usdc);
        tokenOuts[1] = address(usdt);
        address[] memory pairs = new address[](2);
        pairs[0] = address(pairWmonUsdc);
        pairs[1] = address(pairWmonUsdt);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = minOutUsdc;
        minOuts[1] = minOutUsdt;

        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderHash, tokenOuts, pairs, weights, minOuts);

        assertGe(usdc.balanceOf(alice), minOutUsdc, "alice got less USDC than amountOutMin");
        assertGe(usdt.balanceOf(alice), minOutUsdt, "alice got less USDT than amountOutMin");
        assertEq(wmon.balanceOf(address(vault)), 0, "vault retained WMON dust");
    }

    function test_RevertsOnZeroValue() public {
        bytes32 orderHash = keccak256("zero-value");
        _anchor(alice, orderHash);
        (address[] memory t, address[] memory p, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), address(pairWmonUsdc), 10_000, 1);
        vm.prank(alice);
        vm.expectRevert(RoutingVault.ZeroValue.selector);
        vault.executeAndRoute{value: 0}(orderHash, t, p, w, m);
    }

    function test_RevertsOnZeroHash() public {
        (address[] memory t, address[] memory p, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), address(pairWmonUsdc), 10_000, 1);
        vm.prank(alice);
        vm.expectRevert(RoutingVault.ZeroHash.selector);
        vault.executeAndRoute{value: 1 ether}(bytes32(0), t, p, w, m);
    }

    /// Anchor check (audit fix #2): caller must have anchored this exact
    /// orderHash most recently. Without the anchor, the vault reverts.
    function test_RevertsWithoutAnchor() public {
        bytes32 orderHash = keccak256("never-anchored");
        // Deliberately do NOT call _anchor.
        (address[] memory t, address[] memory p, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), address(pairWmonUsdc), 10_000, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RoutingVault.AnchorNotFound.selector, orderHash));
        vault.executeAndRoute{value: 1 ether}(orderHash, t, p, w, m);
    }

    /// Pair allowlist (audit fix #8): pairs not registered at construction
    /// time are rejected.
    function test_RevertsOnUnapprovedPair() public {
        bytes32 orderHash = keccak256("rogue-pair");
        _anchor(alice, orderHash);
        // Deploy a brand-new pair that's NOT in the allowlist.
        MiniAMM rogue = new MiniAMM(address(wmon), address(usdc));
        (address[] memory t, address[] memory p, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), address(rogue), 10_000, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RoutingVault.UnknownPair.selector, 0));
        vault.executeAndRoute{value: 1 ether}(orderHash, t, p, w, m);
    }

    /// Slippage protection: caller-supplied amountOutMin goes DIRECTLY to
    /// MiniAMM.swap as amount0Out/amount1Out. If reserves can't support it,
    /// the AMM reverts (InsufficientOutput if minOut >= reserve, else
    /// InvalidK). Kills the sandwich-DoS vector of quote-then-swap.
    function test_RevertsOnExcessiveSlippage() public {
        bytes32 orderHash = keccak256("slippage");
        _anchor(alice, orderHash);
        (address[] memory t, address[] memory p, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), address(pairWmonUsdc), 10_000, 10_000_000 ether);
        vm.prank(alice);
        vm.expectRevert(); // MiniAMM.InsufficientOutput or InvalidK
        vault.executeAndRoute{value: 1 ether}(orderHash, t, p, w, m);
    }

    function test_RevertsOnNakedSend() public {
        vm.prank(alice);
        vm.expectRevert(RoutingVault.ZeroHash.selector);
        (bool ok, ) = address(vault).call{value: 1 ether}("");
        ok;
    }

    function test_RevertsOnMismatchedPair() public {
        bytes32 orderHash = keccak256("bad-pair");
        _anchor(alice, orderHash);
        // Want USDC but supply the WMON/USDT pair → mismatch.
        (address[] memory t, address[] memory p, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), address(pairWmonUsdt), 10_000, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RoutingVault.InvalidPairTokens.selector, 0));
        vault.executeAndRoute{value: 1 ether}(orderHash, t, p, w, m);
    }

    /// AMM quote MUST match Uniswap V2's exact formula. Pinned per the
    /// fee-bug-regression discipline.
    function test_QuoteMatchesCanonicalV2Formula() public view {
        (uint112 r0, uint112 r1) = pairWmonUsdc.getReserves();
        uint256 amountIn = 0.01 ether;
        bool wmonIsT0 = address(pairWmonUsdc.token0()) == address(wmon);
        uint256 onChainQuote = wmonIsT0
            ? pairWmonUsdc.quoteToken1Out(amountIn)
            : pairWmonUsdc.quoteToken0Out(amountIn);
        uint256 feePerMille = pairWmonUsdc.FEE_PER_MILLE();
        uint256 amountInWithFee = amountIn * (1000 - feePerMille);
        (uint256 reserveIn, uint256 reserveOut) = wmonIsT0
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
        uint256 v2Quote = (amountInWithFee * reserveOut) /
                          (reserveIn * 1000 + amountInWithFee);
        assertEq(onChainQuote, v2Quote, "AMM quote drifted from V2 formula");
        assertEq(feePerMille, 3, "FEE_PER_MILLE must be 3");
    }

    /// k = r0 * r1 must STRICTLY grow after every swap. If k shrinks the
    /// AMM is leaking value.
    function test_KInvariantStrictlyGrowsAfterSwap() public {
        (uint112 r0Before, uint112 r1Before) = pairWmonUsdc.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        bytes32 orderHash = keccak256("k-invariant-test");
        _anchor(alice, orderHash);
        uint256 minOut = _quoteSwap(pairWmonUsdc, 0.05 ether) * 99 / 100;
        (address[] memory t, address[] memory p, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), address(pairWmonUsdc), 10_000, minOut);
        vm.prank(alice);
        vault.executeAndRoute{value: 0.05 ether}(orderHash, t, p, w, m);

        (uint112 r0After, uint112 r1After) = pairWmonUsdc.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);
        assertGt(kAfter, kBefore, "k invariant must STRICTLY grow after swap");
    }

    /// Routed event (renamed from Allocated to avoid collision with
    /// MonadAllocationVault.Allocated, audit fix #3) carries the orderHash
    /// so an indexer can link it to the off-chain signed_orders.json and
    /// the AuditAnchor TX.
    function test_RoutedEventCarriesOrderHash() public {
        bytes32 orderHash = keccak256("event-check");
        _anchor(alice, orderHash);
        uint256 minOut = _quoteSwap(pairWmonUsdc, 1 ether) * 99 / 100;
        (address[] memory t, address[] memory p, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), address(pairWmonUsdc), 10_000, minOut);

        vm.recordLogs();
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderHash, t, p, w, m);

        bytes32 expectedTopic = keccak256(
            "Routed(address,bytes32,uint256,address[],uint256[],uint16[])"
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

    /// skim() recovers tokens force-credited to a pair (audit fix M-2).
    /// Without it an attacker could overflow uint112 by directly
    /// transferring tokens, permanently DoS'ing the pair.
    function test_SkimRecoversForceCreditedTokens() public {
        usdc.faucet(1000 ether);
        usdc.transfer(address(pairWmonUsdc), 100 ether);
        uint256 receiverBalBefore = usdc.balanceOf(address(this));
        pairWmonUsdc.skim(address(this));
        assertEq(usdc.balanceOf(address(this)) - receiverBalBefore, 100 ether,
                 "skim should recover the 100 force-credited USDC");
    }

    // -----------------------------------------------------------------

    function _oneLeg(address tokenOut, address pair, uint16 weight, uint256 minOut)
        internal pure
        returns (address[] memory t, address[] memory p, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](1); t[0] = tokenOut;
        p = new address[](1); p[0] = pair;
        w = new uint16[](1);  w[0] = weight;
        m = new uint256[](1); m[0] = minOut;
    }
}
