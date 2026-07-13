// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm }   from "forge-std/Vm.sol";
import { WMON }      from "../src/dex/WMON.sol";
import { MockToken } from "../src/dex/MockToken.sol";
import { AuditAnchor } from "../src/AuditAnchor.sol";
import { UniswapRoutingVault } from "../src/UniswapRoutingVault.sol";
import { MockV3SwapRouter }    from "./mocks/MockV3SwapRouter.sol";

contract UniswapRoutingVaultTest is Test {
    WMON wmon;
    MockToken usdc;
    MockToken usdt;
    AuditAnchor anchor;
    MockV3SwapRouter router;
    UniswapRoutingVault vault;

    address alice = address(0xA11CE);

    uint24 constant FEE = 3000;
    uint256 constant FUTURE = 1e18; // deadline far in the future

    function setUp() public {
        wmon = new WMON();
        usdc = new MockToken("Test USDC", "mUSDC", 18);
        usdt = new MockToken("Test USDT", "mUSDT", 18);
        anchor = new AuditAnchor();
        router = new MockV3SwapRouter();

        address[] memory approved = new address[](2);
        approved[0] = address(usdc);
        approved[1] = address(usdt);
        vault = new UniswapRoutingVault(
            address(wmon), address(router), address(anchor), approved
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

    function _anchor(address who, bytes32 orderHash) internal {
        vm.prank(who);
        anchor.anchor(orderHash);
    }

    function _twoLeg()
        internal
        view
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](2); t[0] = address(usdc); t[1] = address(usdt);
        f = new uint24[](2);  f[0] = FEE;           f[1] = FEE;
        w = new uint16[](2);  w[0] = 5000;          w[1] = 5000;
        m = new uint256[](2); m[0] = 900 ether;     m[1] = 900 ether; // 0.5 MON * 2000 = 1000; min 900
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

    /// Happy path: 1 MON split 50/50, real router returns MORE than the
    /// caller's minimum (H-1 fix — surplus flows to the user, not LPs).
    function test_HappyPathDeliversAboveMin() public {
        bytes32 orderHash = keccak256("happy");
        _anchor(alice, orderHash);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();

        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);

        // 0.5 MON * 2000 = 1000 tokens each; strictly above the 900 min.
        assertEq(usdc.balanceOf(alice), 1000 ether, "usdc out");
        assertEq(usdt.balanceOf(alice), 1000 ether, "usdt out");
        assertGt(usdc.balanceOf(alice), m[0], "user must receive MORE than the minimum");
        assertEq(wmon.balanceOf(address(vault)), 0, "vault WMON dust");
        // Standing router approval must be cleared after the routine.
        assertEq(
            wmon.allowance(address(vault), address(router)), 0, "router approval not reset"
        );
    }

    /// Odd-value split: last leg absorbs the remainder, whole deposit spent.
    function test_RemainderGoesToLastLeg() public {
        bytes32 orderHash = keccak256("remainder");
        _anchor(alice, orderHash);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        w[0] = 3333; w[1] = 6667;
        m[0] = 0; m[1] = 0;

        uint256 odd = 1 ether + 1; // not divisible cleanly by 10_000
        vm.prank(alice);
        vault.executeAndRoute{value: odd}(orderHash, t, f, w, m, FUTURE);

        // Every wei of WMON was routed -> vault holds nothing.
        assertEq(wmon.balanceOf(address(vault)), 0, "vault must retain no WMON");
        // Total tokens out == odd * 2000 (both legs same rate).
        assertEq(usdc.balanceOf(alice) + usdt.balanceOf(alice), odd * 2000, "total out");
    }

    function test_RevertsOnZeroValue() public {
        bytes32 orderHash = keccak256("zv");
        _anchor(alice, orderHash);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 0);
        vm.prank(alice);
        vm.expectRevert(UniswapRoutingVault.ZeroValue.selector);
        vault.executeAndRoute{value: 0}(orderHash, t, f, w, m, FUTURE);
    }

    function test_RevertsOnZeroHash() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 0);
        vm.prank(alice);
        vm.expectRevert(UniswapRoutingVault.ZeroHash.selector);
        vault.executeAndRoute{value: 1 ether}(bytes32(0), t, f, w, m, FUTURE);
    }

    function test_RevertsOnPastDeadline() public {
        bytes32 orderHash = keccak256("deadline");
        _anchor(alice, orderHash);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 0);
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
            _oneLeg(address(usdc), 10_000, 0);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.AnchorNotFound.selector, orderHash)
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    function test_RevertsOnUnapprovedToken() public {
        bytes32 orderHash = keccak256("bad-token");
        _anchor(alice, orderHash);
        MockToken rogue = new MockToken("Rogue", "RG", 18);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(rogue), 10_000, 0);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.TokenNotApproved.selector, 0, address(rogue))
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    function test_RevertsOnWeightsNotSumming() public {
        bytes32 orderHash = keccak256("weights");
        _anchor(alice, orderHash);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 9999, 0);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.WeightsDoNotSumTo10000.selector, 9999)
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    function test_RevertsOnLengthMismatch() public {
        bytes32 orderHash = keccak256("len");
        _anchor(alice, orderHash);
        address[] memory t = new address[](2);
        t[0] = address(usdc); t[1] = address(usdt);
        uint24[] memory f = new uint24[](1); f[0] = FEE;   // mismatched
        uint16[] memory w = new uint16[](2); w[0] = 5000; w[1] = 5000;
        uint256[] memory m = new uint256[](2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingVault.LengthMismatch.selector, 2));
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE);
    }

    /// Slippage floor: if the router can't meet amountOutMin the whole
    /// routine reverts (the router's TooLittleReceived bubbles up).
    function test_RevertsOnExcessiveSlippage() public {
        bytes32 orderHash = keccak256("slip");
        _anchor(alice, orderHash);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 999_999 ether); // impossible min
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
        _anchor(alice, orderHash);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();

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
