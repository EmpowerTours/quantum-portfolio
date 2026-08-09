// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test }   from "forge-std/Test.sol";
import { MockPQAttestation } from "../mocks/MockPQAttestation.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AuditAnchorV2 }       from "../../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../../src/UniswapRoutingVault.sol";
import { IWrappedNative }      from "../../src/interfaces/IWrappedNative.sol";
import { IV3SwapRouter }       from "../../src/interfaces/IV3SwapRouter.sol";
import { MarketParams }        from "../../src/interfaces/IMorpho.sol";

interface IMorphoFull {
    function owner() external view returns (address);
    function isIrmEnabled(address) external view returns (bool);
    function isLltvEnabled(uint256) external view returns (bool);
    function enableIrm(address) external;
    function enableLltv(uint256) external;
    function createMarket(MarketParams memory) external;
    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
    function idToMarketParams(bytes32 id)
        external
        view
        returns (address, address, address, address, uint256);
}

/// Minimal enabled-IRM stub so Morpho.createMarket's accrual call succeeds.
contract DummyIrm {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(0));
    }
}

/// RED TEAM — RT-04: economics + integration facts that need the real chain.
contract RT04_ForkEconomics is Test {
    address constant WMON   = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant ROUTER = 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;
    address constant MORPHO = 0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee;

    AuditAnchorV2 anchor;
    UniswapRoutingVault vault;
    address tokenOut;
    uint24 fee;
    bool forked;
    uint256 constant FRONTRUN = 400_000 ether;   // sized to actually move this pool

    address victim   = address(0x1CE);
    address attacker = address(0xBAD);

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
        vault = new UniswapRoutingVault(WMON, ROUTER, address(anchor), address(new MockPQAttestation()), approved, tiers);

        vm.deal(victim, 1_000 ether);
        vm.deal(attacker, 2_000_000 ether);
    }

    function _legs()
        internal
        view
        returns (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory m)
    {
        t = new address[](1); t[0] = tokenOut;
        f = new uint24[](1);  f[0] = fee;
        w = new uint16[](1);  w[0] = 10_000;
        m = new uint256[](1); m[0] = 1;      // 0 now reverts ZeroSlippageFloor;
                                             // 1 is the smallest LEGAL floor
    }

    function _anchorRoute(
        address who,
        bytes32 h,
        uint256 amountInWei,
        uint256[] memory m,
        uint256 deadline
    ) internal {
        (address[] memory t, uint24[] memory f, uint16[] memory w, ) = _legs();
        bytes32 c = vault.routeCommitment(h, who, t, f, w, amountInWei, m, deadline);
        uint64 seq = anchor.nextSequence(who);
        vm.prank(who);
        anchor.anchor(h, c, seq);
    }

    /// Fill 10 MON with a throwaway loose floor to learn the fair price, then
    /// rewind. Kept in its own frame to stay under the IR stack limit.
    function _measureFair(bytes32 h) internal returns (uint256 fair) {
        (address[] memory t, uint24[] memory f, uint16[] memory w, uint256[] memory loose) =
            _legs();
        uint256 snap = vm.snapshotState();
        uint256 dl0 = block.timestamp + 300;
        _anchorRoute(victim, h, 10 ether, loose, dl0);
        vm.prank(victim);
        vault.executeAndRoute{ value: 10 ether }(h, t, f, w, loose, dl0);
        fair = IERC20(tokenOut).balanceOf(victim);
        vm.revertToState(snap);
    }

    function _frontRun() internal {
        vm.startPrank(attacker);
        IWrappedNative(WMON).deposit{ value: FRONTRUN }();
        IERC20(WMON).approve(ROUTER, type(uint256).max);
        IV3SwapRouter(ROUTER).exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: WMON, tokenOut: tokenOut, fee: fee, recipient: attacker,
                amountIn: FRONTRUN, amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    function _unwind() internal {
        vm.startPrank(attacker);
        IERC20(tokenOut).approve(ROUTER, type(uint256).max);
        IV3SwapRouter(ROUTER).exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenOut, tokenOut: WMON, fee: fee, recipient: attacker,
                amountIn: IERC20(tokenOut).balanceOf(attacker),
                amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    /// RT-04a — RE-RUN after M-7. Previously the submitter could rewrite the
    /// floor to 1 and the sandwich landed (211509 -> 210855, 30 bps, merely
    /// unprofitable on this deep pool rather than blocked). Now amountOutMin
    /// is part of the commitment, so the anchored floor is the floor that
    /// executes: a front-run that pushes price through it makes the victim's
    /// transaction REVERT instead of filling at the degraded price.
    ///
    /// Sandwiching a correctly-anchored order is therefore no longer possible
    /// — the attacker can only deny service, and denial is free to recover
    /// from because a failed execution does not consume the anchor.
    function test_RT04a_SandwichCannotLandAgainstABoundFloor() public {
        if (!forked) { emit log("SKIP: no MONAD_RPC_URL"); return; }

        uint256 fair = _measureFair(keccak256("baseline"));

        // The agent signs a REAL floor: 5 bps of tolerance.
        (address[] memory t, uint24[] memory f, uint16[] memory w, ) = _legs();
        uint256[] memory bnd = new uint256[](1);
        bnd[0] = (fair * 9995) / 10_000;
        uint256 dl = block.timestamp + 300;
        bytes32 h1 = keccak256("bound-floor");
        _anchorRoute(victim, h1, 10 ether, bnd, dl);

        _frontRun();   // same 400k WMON as the pre-fix run (~30 bps impact)

        // The victim's anchored order can no longer be filled at a loss.
        vm.prank(victim);
        vm.expectRevert(bytes("Too little received"));
        vault.executeAndRoute{ value: 10 ether }(h1, t, f, w, bnd, dl);

        emit log_named_uint("fair fill for 10 MON  ", fair);
        emit log_named_uint("anchored floor (5 bps)", bnd[0]);
        assertEq(IERC20(tokenOut).balanceOf(victim), 0, "victim received nothing at a bad price");
        assertFalse(vault.consumed(victim, h1), "anchor survives the griefed attempt");

        // And it fills normally once the attacker unwinds.
        _unwind();
        vm.prank(victim);
        vault.executeAndRoute{ value: 10 ether }(h1, t, f, w, bnd, dl);
        assertGe(IERC20(tokenOut).balanceOf(victim), bnd[0], "filled at or above the floor");
    }

    /// RT-04c — the RESIDUAL, stated precisely. Binding the floor caps the loss
    /// at the tolerance the agent signed; it does not make MEV impossible. A
    /// front-run whose price impact stays INSIDE that tolerance still fills.
    /// This is inherent to any slippage floor, not a defect — but it means the
    /// floor the agent picks is now the whole defence, so a sloppy generous
    /// floor is the remaining exposure.
    function test_RT04c_ResidualMevIsBoundedByTheAnchoredTolerance() public {
        if (!forked) { emit log("SKIP: no MONAD_RPC_URL"); return; }

        uint256 fair = _measureFair(keccak256("baseline2"));

        // A slack floor: 200 bps of tolerance, well outside the ~30 bps impact.
        (address[] memory t, uint24[] memory f, uint16[] memory w, ) = _legs();
        uint256[] memory slack = new uint256[](1);
        slack[0] = (fair * 9800) / 10_000;
        uint256 dl = block.timestamp + 300;
        bytes32 h1 = keccak256("slack-floor");
        _anchorRoute(victim, h1, 10 ether, slack, dl);

        _frontRun();

        vm.prank(victim);
        vault.executeAndRoute{ value: 10 ether }(h1, t, f, w, slack, dl);
        uint256 got = IERC20(tokenOut).balanceOf(victim);

        emit log_named_uint("fair fill        ", fair);
        emit log_named_uint("anchored floor   ", slack[0]);
        emit log_named_uint("sandwiched fill  ", got);
        emit log_named_uint("realised loss bps", (fair - got) * 10_000 / fair);

        assertLt(got, fair, "a sandwich inside the tolerance still lands");
        assertGe(got, slack[0], "but never below the floor the agent signed");
    }

    /// RT-04b — CONFIRM the new market allowlist key matches Morpho's own id
    /// derivation. Create a market on real Morpho and check the adapter's
    /// keccak256(abi.encode(params)) indexes it.
    function test_RT04b_MarketIdDerivationMatchesRealMorpho() public {
        if (!forked) { emit log("SKIP: no MONAD_RPC_URL"); return; }

        IMorphoFull mo = IMorphoFull(MORPHO);
        address irm = address(new DummyIrm());
        uint256 lltv = 86e16;

        address owner = mo.owner();
        vm.startPrank(owner);
        if (!mo.isIrmEnabled(irm))  mo.enableIrm(irm);
        if (!mo.isLltvEnabled(lltv)) mo.enableLltv(lltv);
        vm.stopPrank();

        MarketParams memory p = MarketParams({
            loanToken: WMON,
            collateralToken: tokenOut,
            oracle: address(0xBBBB),
            irm: irm,
            lltv: lltv
        });
        mo.createMarket(p);

        bytes32 adapterId = keccak256(abi.encode(p)); // MorphoSupplyAdapter's key
        (, , , , uint128 lastUpdate, ) = mo.market(adapterId);
        assertGt(lastUpdate, 0, "adapter's marketId does NOT index the real Morpho market");

        (address l, address c, address o, address i, uint256 v) = mo.idToMarketParams(adapterId);
        assertEq(l, p.loanToken);
        assertEq(c, p.collateralToken);
        assertEq(o, p.oracle);
        assertEq(i, p.irm);
        assertEq(v, p.lltv);
    }
}
