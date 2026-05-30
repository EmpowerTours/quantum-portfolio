// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { WMON } from "../src/dex/WMON.sol";
import { MockToken } from "../src/dex/MockToken.sol";
import { MiniAMM } from "../src/dex/MiniAMM.sol";
import { RoutingVault } from "../src/RoutingVault.sol";

contract RoutingVaultTest is Test {
    WMON wmon;
    MockToken usdc;
    MockToken usdt;
    MiniAMM pairWmonUsdc;
    MiniAMM pairWmonUsdt;
    RoutingVault vault;

    address alice = address(0xA11CE);
    address lp    = address(0x11111);

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("Test USDC", "mUSDC", 18);
        usdt = new MockToken("Test USDT", "mUSDT", 18);
        pairWmonUsdc = new MiniAMM(address(wmon), address(usdc));
        pairWmonUsdt = new MiniAMM(address(wmon), address(usdt));
        vault = new RoutingVault(payable(address(wmon)));

        vm.deal(lp, 100 ether);
        usdc.faucet(50_000 ether);
        usdt.faucet(50_000 ether);
        usdc.transfer(lp, 50_000 ether);
        usdt.transfer(lp, 50_000 ether);

        vm.startPrank(lp);
        wmon.deposit{value: 20 ether}();

        // Add liquidity in pair-token-order (constructor sorted by address).
        _addLp(pairWmonUsdc, address(wmon), 10 ether, address(usdc), 25_000 ether);
        _addLp(pairWmonUsdt, address(wmon), 10 ether, address(usdt), 25_000 ether);
        vm.stopPrank();

        vm.deal(alice, 10 ether);
    }

    /// Sort amounts by token address so addLiquidity gets (token0, token1) order.
    function _addLp(MiniAMM pair, address tA, uint256 amtA, address tB, uint256 amtB) internal {
        wmon.approve(address(pair), type(uint256).max);
        usdc.approve(address(pair), type(uint256).max);
        usdt.approve(address(pair), type(uint256).max);
        (uint256 amount0, uint256 amount1) = tA < tB ? (amtA, amtB) : (amtB, amtA);
        pair.addLiquidity(amount0, amount1, lp);
    }

    /// Happy path: alice deposits 1 MON, vault splits 50/50, swaps each
    /// leg, alice receives both tokens.
    function test_ExecuteAndRouteHappyPath() public {
        bytes32 orderHash = keccak256("happy-order");
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
        minOuts[0] = 1; // accept any non-zero
        minOuts[1] = 1;

        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderHash, tokenOuts, pairs, weights, minOuts);

        // Alice should have received some USDC and some USDT.
        assertGt(usdc.balanceOf(alice), 0, "alice has no USDC after swap");
        assertGt(usdt.balanceOf(alice), 0, "alice has no USDT after swap");
        // Vault should be empty (no residual WMON).
        assertEq(wmon.balanceOf(address(vault)), 0, "vault retained WMON dust");
    }

    function test_RevertsOnZeroValue() public {
        bytes32 orderHash = keccak256("zero-value");
        address[] memory tokenOuts = new address[](1);
        address[] memory pairs = new address[](1);
        uint16[]  memory weights = new uint16[](1);
        uint256[] memory minOuts = new uint256[](1);
        tokenOuts[0] = address(usdc);
        pairs[0] = address(pairWmonUsdc);
        weights[0] = 10_000;
        minOuts[0] = 1;
        vm.prank(alice);
        vm.expectRevert(RoutingVault.ZeroValue.selector);
        vault.executeAndRoute{value: 0}(orderHash, tokenOuts, pairs, weights, minOuts);
    }

    function test_RevertsOnZeroHash() public {
        address[] memory tokenOuts = new address[](1);
        address[] memory pairs = new address[](1);
        uint16[]  memory weights = new uint16[](1);
        uint256[] memory minOuts = new uint256[](1);
        tokenOuts[0] = address(usdc);
        pairs[0] = address(pairWmonUsdc);
        weights[0] = 10_000;
        minOuts[0] = 1;
        vm.prank(alice);
        vm.expectRevert(RoutingVault.ZeroHash.selector);
        vault.executeAndRoute{value: 1 ether}(bytes32(0), tokenOuts, pairs, weights, minOuts);
    }

    function test_RevertsOnSlippage() public {
        bytes32 orderHash = keccak256("slippage");
        address[] memory tokenOuts = new address[](1);
        address[] memory pairs = new address[](1);
        uint16[]  memory weights = new uint16[](1);
        uint256[] memory minOuts = new uint256[](1);
        tokenOuts[0] = address(usdc);
        pairs[0] = address(pairWmonUsdc);
        weights[0] = 10_000;
        minOuts[0] = 10_000_000 * 10 ** 18; // absurdly high

        vm.prank(alice);
        vm.expectRevert(); // SlippageTooHigh(...)
        vault.executeAndRoute{value: 1 ether}(orderHash, tokenOuts, pairs, weights, minOuts);
    }

    function test_RevertsOnNakedSend() public {
        vm.prank(alice);
        vm.expectRevert(RoutingVault.ZeroHash.selector);
        (bool ok, ) = address(vault).call{value: 1 ether}("");
        ok;
    }

    function test_RevertsOnMismatchedPair() public {
        bytes32 orderHash = keccak256("bad-pair");
        address[] memory tokenOuts = new address[](1);
        address[] memory pairs = new address[](1);
        uint16[]  memory weights = new uint16[](1);
        uint256[] memory minOuts = new uint256[](1);
        // Claim we want USDC but supply the WMON/USDT pair → mismatch.
        tokenOuts[0] = address(usdc);
        pairs[0] = address(pairWmonUsdt);
        weights[0] = 10_000;
        minOuts[0] = 1;

        vm.prank(alice);
        vm.expectRevert(); // InvalidPair(0)
        vault.executeAndRoute{value: 1 ether}(orderHash, tokenOuts, pairs, weights, minOuts);
    }

    /// Allocated event must carry the orderHash so an indexer can link
    /// it to the off-chain signed_orders.json and the AuditAnchor TX.
    function test_AllocatedEventCarriesOrderHash() public {
        bytes32 orderHash = keccak256("event-check");
        address[] memory tokenOuts = new address[](1);
        address[] memory pairs = new address[](1);
        uint16[]  memory weights = new uint16[](1);
        uint256[] memory minOuts = new uint256[](1);
        tokenOuts[0] = address(usdc);
        pairs[0] = address(pairWmonUsdc);
        weights[0] = 10_000;
        minOuts[0] = 1;

        vm.recordLogs();
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderHash, tokenOuts, pairs, weights, minOuts);

        // Find the Allocated log emitted by the vault.
        bytes32 expectedTopic = keccak256(
            "Allocated(address,bytes32,uint256,address[],uint256[],uint16[])"
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
        assertTrue(found, "Allocated event with correct orderHash not emitted");
    }
}

