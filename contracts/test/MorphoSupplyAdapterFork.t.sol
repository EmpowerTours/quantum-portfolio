// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test }   from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AuditAnchor }        from "../src/AuditAnchor.sol";
import { MorphoSupplyAdapter } from "../src/MorphoSupplyAdapter.sol";
import { IMorpho, MarketParams } from "../src/interfaces/IMorpho.sol";

/// @notice Opt-in integration test against the REAL Morpho Blue deployment on
///         a Monad-mainnet fork. Proves the adapter supplies USDC into the
///         live USDC/WBTC lending market (the yield-deposit leg), anchor-gated.
///
///         Self-skips (no failure) unless MONAD_RPC_URL is set:
///           MONAD_RPC_URL=https://rpc.monad.xyz \
///           forge test --match-contract MorphoSupplyAdapterForkTest -vvv
contract MorphoSupplyAdapterForkTest is Test {
    // Morpho Blue on Monad mainnet + the funded USDC/WBTC market params.
    address constant MORPHO    = 0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee;
    address constant USDC      = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address constant WBTC      = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
    address constant ORACLE    = 0xff07261c87763cc5693ab78746d0b6735Ec626F5;
    address constant IRM       = 0x09475a3D6eA8c314c592b1a3799bDE044E2F400F;
    uint256 constant LLTV      = 860000000000000000;

    AuditAnchor anchor;
    MorphoSupplyAdapter adapter;
    address trader = address(0xBEEF);
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // no RPC -> self-skip

        vm.createSelectFork(rpc);
        require(block.chainid == 143, "fork is not Monad mainnet");
        forked = true;

        anchor = new AuditAnchor();
        address[] memory approved = new address[](1);
        approved[0] = USDC;
        adapter = new MorphoSupplyAdapter(MORPHO, address(anchor), approved);
    }

    function _market() internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: USDC,
            collateralToken: WBTC,
            oracle: ORACLE,
            irm: IRM,
            lltv: LLTV
        });
    }

    function test_SuppliesUsdcIntoLiveMorphoMarket() public {
        if (!forked) {
            emit log("SKIP: set MONAD_RPC_URL to run the Morpho fork test");
            return;
        }

        MarketParams memory m = _market();
        bytes32 id = keccak256(abi.encode(m));
        bytes32 orderHash = keccak256("fork-live-morpho-supply");
        uint256 amount = 1_000_000; // 1 USDC (6 decimals)

        // Provenance: the trader anchors the order, then supplies.
        vm.startPrank(trader);
        anchor.anchor(orderHash);

        deal(USDC, trader, amount);
        IERC20(USDC).approve(address(adapter), amount);

        (uint256 supplySharesBefore,,) = IMorpho(MORPHO).position(id, trader);
        uint256 shares = adapter.supply(orderHash, m, amount);
        (uint256 supplySharesAfter,,) = IMorpho(MORPHO).position(id, trader);
        vm.stopPrank();

        // The user now owns a real supply position; the adapter holds no dust.
        assertGt(shares, 0, "no supply shares minted");
        assertEq(supplySharesAfter - supplySharesBefore, shares, "shares mismatch");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "adapter retained USDC dust");
    }

    function test_RevertsWithoutAnchor() public {
        if (!forked) return;
        MarketParams memory m = _market();
        vm.startPrank(trader);
        deal(USDC, trader, 1_000_000);
        IERC20(USDC).approve(address(adapter), 1_000_000);
        vm.expectRevert(); // AnchorNotFound — trader never anchored
        adapter.supply(keccak256("never-anchored"), m, 1_000_000);
        vm.stopPrank();
    }
}
