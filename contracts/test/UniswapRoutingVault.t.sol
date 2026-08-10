// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { PQExecBinding } from "../src/PQExecBinding.sol";
import { PQBind } from "./helpers/PQBind.sol";
import { MockPQAttestation } from "./mocks/MockPQAttestation.sol";
import { Vm }   from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
            address(wmon), address(router), address(anchor), address(new MockPQAttestation()), approved, fees
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
    /// @dev Same derivation as _anchorFor but WITHOUT anchoring, so a test can
    ///      reach the anchor check with a valid PQ binding in hand. Without it
    ///      "reverts without an anchor" would pass for the wrong reason — the
    ///      binding check runs first and would reject the preimage.
    function _bindOnly(
        address who,
        address[] memory t,
        uint24[] memory f,
        uint16[] memory w,
        uint256 amountInWei,
        uint256[] memory m,
        uint256 deadline
    ) internal view returns (bytes32 orderHash, bytes memory pre) {
        bytes32 paramsHash = keccak256(
            abi.encode(block.chainid, address(vault), who, t, f, w, amountInWei, m, deadline)
        );
        (pre, orderHash) = PQBind.preimage(paramsHash);
    }

    /// @dev Derives the orderHash rather than taking one, because the executor
    ///      now requires bytes that hash to it AND carry the matching
    ///      exec_commitment. A test can no longer invent an orderHash — which
    ///      is the entire point of the fix, so the helper does the work a real
    ///      signer does. Returns both so the caller can pass the preimage on.
    function _anchorFor(
        address who,
        address[] memory t,
        uint24[] memory f,
        uint16[] memory w,
        uint256 amountInWei,
        uint256[] memory m,
        uint256 deadline
    ) internal returns (bytes32 orderHash, bytes memory pre) {
        bytes32 paramsHash = keccak256(
            abi.encode(block.chainid, address(vault), who, t, f, w, amountInWei, m, deadline)
        );
        (pre, orderHash) = PQBind.preimage(paramsHash);
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
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);

        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);

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
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        w[0] = 3333; w[1] = 6667;
        m[0] = 1; m[1] = 1;

        uint256 odd = 1 ether + 1; // not divisible cleanly by 10_000
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, odd, m, FUTURE);
        vm.prank(alice);
        vault.executeAndRoute{value: odd}(orderHash, t, f, w, m, FUTURE, orderHash_pre);

        assertEq(wmon.balanceOf(address(vault)), 0, "vault must retain no WMON");
        assertEq(usdc.balanceOf(alice) + usdt.balanceOf(alice), odd * 2000, "total out");
    }

    // --- M-6: execution binding + single use ------------------------------

    /// Binding: the anchor commits to specific parameters; executing DIFFERENT
    /// parameters under the same orderHash must revert.
    function test_M6_RevertsWhenExecutionDivergesFromAnchor() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);

        // Flip the weights. The PQ binding now catches this BEFORE the anchor
        // comparison does, because the weights are inside the signed
        // exec_commitment as well as inside the anchored commitment. Assert the
        // binding layer explicitly...
        uint16[] memory wFlipped = new uint16[](2);
        wFlipped[0] = 9000; wFlipped[1] = 1000;
        bytes32 signedParams = keccak256(
            abi.encode(block.chainid, address(vault), alice, t, f, w, uint256(1 ether), m, FUTURE)
        );
        bytes32 flippedParams = keccak256(
            abi.encode(block.chainid, address(vault), alice, t, f, wFlipped, uint256(1 ether), m, FUTURE)
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            PQExecBinding.ExecCommitmentMismatch.selector, signedParams, flippedParams
        ));
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, wFlipped, m, FUTURE, orderHash_pre);
        w = wFlipped;

        // ...and keep the ORIGINAL M-6 property — that the anchor records the
        // un-flipped execution and a divergent one does not match it — as a
        // direct state assertion, so it survives the guard order changing.
        bytes32 divergent = vault.routeCommitment(orderHash, alice, t, f, w, 1 ether, m, FUTURE);
        bytes32 recorded  = anchor.execCommitmentOf(alice, orderHash);
        assertTrue(divergent != recorded, "M-6: a divergent execution must not match the anchor");
    }

    /// Binding covers msg.value too: same allocation, different size, rejected.
    function test_M6_RevertsWhenValueDivergesFromAnchor() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);

        vm.prank(alice);
        vm.expectRevert();
        vault.executeAndRoute{value: 2 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);
    }

    /// M-7: the commitment must cover `amountOutMin`. Anchoring an intent with
    /// a real slippage floor and then submitting a floor of 1 is exactly how a
    /// compromised broadcaster deviates from PQ-signed intent while still
    /// producing a correctly-anchored trade.
    function test_M7_RevertsWhenSlippageFloorDivergesFromAnchor() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);

        // Signed intent said 900 ether per leg; broadcaster tries to drop it to 1.
        m[0] = 1; m[1] = 1;
        vm.prank(alice);
        vm.expectRevert();
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);
    }

    /// M-7: the commitment must cover `deadline`, so an expired order cannot be
    /// replayed later under a fresh deadline.
    function test_M7_RevertsWhenDeadlineDivergesFromAnchor() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);

        vm.prank(alice);
        vm.expectRevert();
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, type(uint256).max, orderHash_pre);
    }

    /// Single use: one anchor authorises exactly one execution.
    function test_M6_RevertsOnReplayOfSameAnchor() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);

        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);

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
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);
    }

    /// L-1: anchoring the NEXT order must not strand an in-flight earlier one.
    function test_L1_PipeliningDoesNotStrandEarlierOrder() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();

        (bytes32 orderN, bytes memory orderN_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);
        (bytes32 orderN1, bytes memory orderN1_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE - 1);

        // Order N still executes even though N+1 was anchored after it.
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderN, t, f, w, m, FUTURE, orderN_pre);
        assertGt(usdc.balanceOf(alice), 0, "order N must still be executable");

        // And N+1 executes independently.
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderN1, t, f, w, m, FUTURE - 1, orderN1_pre);
    }

    // --- allowance hygiene ------------------------------------------------

    /// A mutation sweep deleted `forceApprove(ROUTER, 0)` after the swap loop
    /// and every test still passed. A standing WMON allowance would let the
    /// router pull from this vault later, outside any anchored order — funds
    /// that belong to whoever deposits next.
    function test_AllowanceToRouterIsResetToZeroAfterRouting() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 1);
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);

        assertEq(
            IERC20(address(wmon)).allowance(address(vault), address(router)), 0,
            "vault must leave no standing WMON allowance to the router"
        );
    }

    /// The reset must hold across consecutive orders, not just the first.
    function test_AllowanceStaysZeroAcrossTwoOrders() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 1);
        (bytes32 o1, bytes memory o1_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(o1, t, f, w, m, FUTURE, o1_pre);
        (bytes32 o2, bytes memory o2_pre) = _anchorFor(alice, t, f, w, 0.5 ether, m, FUTURE);
        vm.prank(alice);
        vault.executeAndRoute{value: 0.5 ether}(o2, t, f, w, m, FUTURE, o2_pre);

        assertEq(IERC20(address(wmon)).allowance(address(vault), address(router)), 0);
        assertEq(IERC20(address(wmon)).balanceOf(address(vault)), 0, "no WMON dust retained");
    }

    // --- new per-leg guards ----------------------------------------------

    /// M-5: a zero-weight leg would floor amountIn to 0, which SwapRouter02
    /// reads as its CONTRACT_BALANCE sentinel. Rejected outright — by the
    /// semantic weight check (`ZeroWeightBps`), which now runs BEFORE the
    /// quantity check. See RT07h for why both are required.
    function test_M5_RevertsOnZeroWeightLeg() public {
        address[] memory t = new address[](2);
        t[0] = address(usdc); t[1] = address(usdt);
        uint24[] memory f = new uint24[](2);  f[0] = FEE;  f[1] = FEE;
        uint16[] memory w = new uint16[](2);  w[0] = 0;    w[1] = 10_000;
        uint256[] memory m = new uint256[](2); m[0] = 1;   m[1] = 1;

        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingVault.ZeroWeightBps.selector, 0));
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);
    }

    /// H-3: fee tiers select the POOL; unapproved tiers can be near-empty.
    function test_H3_RevertsOnUnapprovedFeeTier() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 1);
        f[0] = 100; // dust pool tier, not allowlisted
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.FeeTierNotApproved.selector, 0, uint24(100))
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);
    }

    /// L-2: an unbounded slippage floor is fail-open on a thin pool.
    function test_L2_RevertsOnZeroSlippageFloor() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 0);
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.ZeroSlippageFloor.selector, 0)
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);
    }

    // --- pre-existing guards ---------------------------------------------

    function test_RevertsOnZeroValue() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 1);
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(UniswapRoutingVault.ZeroValue.selector);
        vault.executeAndRoute{value: 0}(orderHash, t, f, w, m, FUTURE, orderHash_pre);
    }

    function test_RevertsOnZeroHash() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 1);
        vm.prank(alice);
        vm.expectRevert(UniswapRoutingVault.ZeroHash.selector);
        // ZeroHash is checked before the PQ binding, so the preimage is
        // irrelevant here — which this also asserts by passing empty bytes.
        vault.executeAndRoute{value: 1 ether}(bytes32(0), t, f, w, m, FUTURE, "");
    }

    function test_RevertsOnPastDeadline() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 1);
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);
        vm.warp(1_000_000);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.DeadlinePassed.selector, 999_999, 1_000_000)
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, 999_999, orderHash_pre);
    }

    function test_RevertsWithoutAnchor() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 1);
        // Valid binding, deliberately unanchored: the anchor check must be the
        // one that fails.
        (bytes32 orderHash, bytes memory orderHash_pre) =
            _bindOnly(alice, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.AnchorNotFound.selector, orderHash)
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);
    }

    function test_RevertsOnUnapprovedToken() public {
        MockToken rogue = new MockToken("Rogue", "RG", 18);
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(rogue), 10_000, 1);
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.TokenNotApproved.selector, 0, address(rogue))
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);
    }

    function test_RevertsOnWeightsNotSumming() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 9999, 1);
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.WeightsDoNotSumTo10000.selector, 9999)
        );
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);
    }

    function test_RevertsOnLengthMismatch() public {
        address[] memory t = new address[](2);
        t[0] = address(usdc); t[1] = address(usdt);
        uint24[] memory f = new uint24[](1); f[0] = FEE;   // mismatched
        uint16[] memory w = new uint16[](2); w[0] = 5000; w[1] = 5000;
        uint256[] memory m = new uint256[](2); m[0] = 1; m[1] = 1;
        // LengthMismatch is checked before the PQ binding, so any well-formed
        // preimage reaches it; this asserts the ORDER of the guards too.
        (bytes32 orderHash, bytes memory orderHash_pre) =
            _bindOnly(alice, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingVault.LengthMismatch.selector, 2));
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);
    }

    /// Slippage floor: if the router can't meet amountOutMin the whole
    /// routine reverts (the router's TooLittleReceived bubbles up).
    function test_RevertsOnExcessiveSlippage() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) =
            _oneLeg(address(usdc), 10_000, 999_999 ether); // impossible min
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);
        vm.prank(alice);
        vm.expectRevert();
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);
    }

    function test_RevertsOnNakedSend() public {
        vm.prank(alice);
        vm.expectRevert(UniswapRoutingVault.ZeroHash.selector);
        (bool ok, ) = address(vault).call{value: 1 ether}("");
        ok;
    }

    function test_RoutedEventCarriesOrderHash() public {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m) = _twoLeg();
        (bytes32 orderHash, bytes memory orderHash_pre) = _anchorFor(alice, t, f, w, 1 ether, m, FUTURE);

        vm.recordLogs();
        vm.prank(alice);
        vault.executeAndRoute{value: 1 ether}(orderHash, t, f, w, m, FUTURE, orderHash_pre);

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
