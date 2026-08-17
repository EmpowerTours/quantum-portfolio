// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test }   from "forge-std/Test.sol";
import { MockPQAttestation } from "../mocks/MockPQAttestation.sol";
import { PQBind } from "../helpers/PQBind.sol";
import { Vm }     from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AuditAnchorV2 }       from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { IWrappedNative }      from "../../src/interfaces/IWrappedNative.sol";
import { IV3SwapRouter }       from "../../src/interfaces/IV3SwapRouter.sol";

/// RED TEAM — RT-01  (finding M-5, now FIXED — these tests assert the fix)
///
/// ORIGINAL EXPLOIT (against the pre-fix vault):
///   UniswapRoutingVault.executeAndRoute passed `amountIn` straight to
///   SwapRouter02.exactInputSingle. In SwapRouter02, `amountIn == 0` is NOT
///   "swap nothing": it is the magic sentinel `Constants.CONTRACT_BALANCE`,
///   which makes the router (a) substitute its OWN tokenIn balance for
///   amountIn and (b) flip the payer from msg.sender to address(this).
///
///       if (params.amountIn == Constants.CONTRACT_BALANCE) {   // == 0
///           hasAlreadyPaid = true;
///           params.amountIn = IERC20(params.tokenIn).balanceOf(address(this));
///       }
///       ... payer: hasAlreadyPaid ? address(this) : msg.sender
///
///   The vault produced amountIn == 0 whenever weightsBps[i] == 0. Recipient
///   is msg.sender, so any WMON stranded in SwapRouter02 was swapped and
///   delivered to the caller for free, the last leg silently absorbed the
///   zero-weight slice, and the `Routed` event attributed the swept output to
///   an allocation slice the user never funded. Measured on a Monad mainnet
///   fork: 1 MON in yielded 84742 tokenOut vs 21185 in the control, and the
///   router's 3 WMON went to 0. The balance-delta dust invariant never fired,
///   because the vault's own WMON balance was untouched.
///
/// FIX: `if (weightsBps[i] == 0) revert ZeroWeightBps(i);` — plus the separate
///      post-arithmetic quantity check `if (amountIn == 0) revert
///      ZeroWeightLeg(i);`. Both are required; see RT07 and RT07h for why
///      neither subsumes the other.
///      (src/UniswapRoutingVault.sol, inside the routing loop).
///
/// Fork test — needs MONAD_RPC_URL / FORK_TOKEN_OUT / FORK_FEE, self-skips
/// otherwise.
contract RT01_ZeroAmountRouterSentinel is Test {
    address constant WMON   = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant ROUTER = 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;

    AuditAnchorV2 anchor;
    UniswapRoutingVault vault;
    address tokenOut;
    uint24 fee;

    address attacker = address(0xBADBAD);
    address victimLP = address(0xF00D);

    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        require(block.chainid == 143, "fork is not Monad mainnet");

        // Read the pool params BEFORE arming `forked`: envAddress/envUint revert
        // on a missing key, so an RPC without them used to fail setUp outright
        // instead of self-skipping like the no-RPC path.
        tokenOut = vm.envOr("FORK_TOKEN_OUT", address(0));
        fee = uint24(vm.envOr("FORK_FEE", uint256(0)));
        if (tokenOut == address(0) || fee == 0) return;  // forked stays false -> skips
        forked = true;

        anchor = new AuditAnchorV2();
        address[] memory approved = new address[](1);
        approved[0] = tokenOut;
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = fee;
        vault = new UniswapRoutingVault(WMON, ROUTER, address(anchor), address(new MockPQAttestation()), approved, tiers);

        vm.deal(attacker, 100 ether);
        vm.deal(victimLP, 100 ether);
    }

    /// Someone strands WMON in SwapRouter02 (happens constantly in practice:
    /// mis-sent tokens, aborted multicalls, refund dust). Model it explicitly.
    function _strandWmonInRouter(uint256 amount) internal {
        vm.startPrank(victimLP);
        IWrappedNative(WMON).deposit{ value: amount }();
        IERC20(WMON).transfer(ROUTER, amount);
        vm.stopPrank();
    }

    /// @dev The orderHash is DERIVED, not invented: the executor now requires
    ///      bytes that sha256 to it and carry the matching exec_commitment, so
    ///      the test has to do the work a real signer does. Returns the preimage
    ///      so the caller can hand it to executeAndRoute.
    function _anchorRoute(
        address who,
        address[] memory t,
        uint24[] memory f,
        uint16[] memory w,
        uint256 amountInWei,
        uint256[] memory m,
        uint256 deadline
    ) internal returns (bytes32 h, bytes memory pre) {
        bytes32 paramsHash = keccak256(
            abi.encode(block.chainid, address(vault), who, t, f, w, amountInWei, m, deadline)
        );
        (pre, h) = PQBind.preimage(paramsHash);
        bytes32 c = vault.routeCommitment(h, who, t, f, w, amountInWei, m, deadline);
        uint64 _seq = anchor.nextSequence(who);
        vm.prank(who);
        anchor.anchor(h, c, _seq);
    }

    /// UNCHANGED — this is a property of Uniswap's SwapRouter02, not of our
    /// contracts, and it is still true on Monad mainnet today. Kept as
    /// documentation of the external hazard the vault now defends against:
    /// calling the router DIRECTLY with amountIn == 0 spends the ROUTER's own
    /// balance and pays out to `recipient`, with no approval and no balance.
    function test_RT01a_RouterTreatsZeroAmountInAsSweepItsOwnBalance() public {
        if (!forked) { vm.skip(true); return; }   // reports as SKIPPED, not PASSED

        _strandWmonInRouter(1 ether);
        assertEq(IERC20(WMON).balanceOf(ROUTER), 1 ether, "setup");

        uint256 attackerWmonBefore = IERC20(WMON).balanceOf(attacker);
        uint256 attackerOutBefore  = IERC20(tokenOut).balanceOf(attacker);

        vm.prank(attacker);
        uint256 out = IV3SwapRouter(ROUTER).exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: WMON,
                tokenOut: tokenOut,
                fee: fee,
                recipient: attacker,
                amountIn: 0,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        emit log_named_uint("tokenOut swept from router", out);
        assertGt(out, 0, "amountIn==0 should have been a no-op if honoured literally");
        assertEq(IERC20(WMON).balanceOf(ROUTER), 0, "router balance was spent");
        assertEq(IERC20(WMON).balanceOf(attacker), attackerWmonBefore, "attacker paid no WMON");
        assertGt(IERC20(tokenOut).balanceOf(attacker), attackerOutBefore, "attacker profited");
    }

    /// INVERTED — the exploit path through the vault is now closed. Same
    /// attack setup that previously turned 1 MON into 84742 tokenOut by
    /// draining 3 WMON from the router; the vault now refuses the zero-weight
    /// leg before any swap, and the router's balance is untouched.
    function test_RT01b_ZeroWeightLegNowRevertsInsteadOfSweepingRouter() public {
        if (!forked) { vm.skip(true); return; }   // reports as SKIPPED, not PASSED

        _strandWmonInRouter(3 ether);
        uint256 routerBefore = IERC20(WMON).balanceOf(ROUTER);

        address[] memory t = new address[](2); t[0] = tokenOut;  t[1] = tokenOut;
        uint24[]  memory f = new uint24[](2);  f[0] = fee;       f[1] = fee;
        uint16[]  memory w = new uint16[](2);  w[0] = 0;         w[1] = 10_000;
        uint256[] memory m = new uint256[](2); m[0] = 1;         m[1] = 1;

        // Sign AND anchor the hostile allocation honestly — the PQ binding is
        // satisfied and the commitment matches, so the ONLY thing standing
        // between the attacker and the sweep is the new zero-weight guard.
        uint256 dl = block.timestamp + 1;
        (bytes32 h, bytes memory pre) = _anchorRoute(attacker, t, f, w, 1 ether, m, dl);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingVault.ZeroWeightBps.selector, 0));
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, dl, pre);

        assertEq(IERC20(WMON).balanceOf(ROUTER), routerBefore, "router's WMON NOT swept");
        assertEq(IERC20(tokenOut).balanceOf(attacker), 0, "attacker gained nothing");
    }

    /// INVERTED — the audit-trail corruption is no longer producible. The
    /// pre-fix vault emitted `Routed` with amountInWei = 1e18 but
    /// amountsOut[0] = 42371 against a 0-bps leg, laundering the swept router
    /// balance into a hash-anchored trade record. Now no Routed event can be
    /// emitted at all for such an allocation.
    function test_RT01e_NoRoutedEventCanBeEmittedForAZeroWeightLeg() public {
        if (!forked) { vm.skip(true); return; }   // reports as SKIPPED, not PASSED

        _strandWmonInRouter(2 ether);

        address[] memory t = new address[](2); t[0] = tokenOut; t[1] = tokenOut;
        uint24[]  memory f = new uint24[](2);  f[0] = fee;      f[1] = fee;
        uint16[]  memory w = new uint16[](2);  w[0] = 0;        w[1] = 10_000;
        uint256[] memory m = new uint256[](2); m[0] = 1;        m[1] = 1;
        uint256 dl = block.timestamp + 1;
        (bytes32 h, bytes memory pre) = _anchorRoute(attacker, t, f, w, 1 ether, m, dl);

        vm.recordLogs();
        vm.prank(attacker);
        try vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, dl, pre) {
            fail();
        } catch { /* expected */ }

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256(
            "Routed(address,bytes32,uint256,address[],uint24[],uint256[],uint16[])"
        );
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                !(logs[i].topics[0] == sig && logs[i].emitter == address(vault)),
                "a Routed event was emitted for a zero-weight allocation"
            );
        }
    }

    /// INVERTED — the liveness half of M-5. An honest order carrying a sub-
    /// 0.01% pool (src/monad_tx.py `fractional_weights_to_bps` does
    /// `int(w * 10_000)`, which floors such a weight to 0) used to revert deep
    /// inside UniswapV3Pool with an opaque "AS". It now fails fast at the
    /// vault boundary with a named error that tells the agent exactly which
    /// leg to drop before signing.
    function test_RT01d_ZeroWeightLegFailsFastWithNamedError() public {
        if (!forked) { vm.skip(true); return; }   // reports as SKIPPED, not PASSED

        assertEq(IERC20(WMON).balanceOf(ROUTER), 0, "precondition: router empty");

        address[] memory t = new address[](2); t[0] = tokenOut; t[1] = tokenOut;
        uint24[]  memory f = new uint24[](2);  f[0] = fee;      f[1] = fee;
        uint16[]  memory w = new uint16[](2);  w[0] = 0;        w[1] = 10_000;
        uint256[] memory m = new uint256[](2); m[0] = 1;        m[1] = 1;
        uint256 dl = block.timestamp + 1;
        (bytes32 h, bytes memory pre) = _anchorRoute(attacker, t, f, w, 1 ether, m, dl);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingVault.ZeroWeightBps.selector, 0));
        vault.executeAndRoute{ value: 1 ether }(h, t, f, w, m, dl, pre);
    }
}
