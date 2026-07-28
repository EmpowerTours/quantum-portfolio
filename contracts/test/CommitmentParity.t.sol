// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { AuditAnchorV2 }       from "../src/AuditAnchorV2.sol";
import { UniswapRoutingVault } from "../src/UniswapRoutingVault.sol";
import { MorphoSupplyAdapter } from "../src/MorphoSupplyAdapter.sol";
import { MarketParams }        from "../src/interfaces/IMorpho.sol";

/// @notice Cross-language parity for the AuditAnchorV2 execution commitments.
///
///         The off-chain agent computes `execCommitment` in Python
///         (`src/monad_tx.route_commitment` / `supply_commitment`) and anchors
///         it; the executor recomputes it in Solidity from its own calldata
///         and refuses to proceed on a mismatch. Two independent
///         implementations of one hash is exactly the place a silent
///         divergence would live — and the failure mode is not a revert but a
///         permanently unusable anchor (a mis-committed order can never be
///         re-anchored; see AuditAnchorV2.AlreadyAnchored).
///
///         The golden values below were produced by `cast abi-encode | cast
///         keccak` and independently reproduced by the Python builders. The
///         matching Python assertions live in `tests/test_monad_tx.py`
///         (`test_route_commitment_matches_solidity_golden`), so a change to
///         either side fails one of the two suites.
///
///         If you are here because this test failed: do NOT update the golden.
///         One of the two implementations has drifted, and shipping that
///         divergence bricks every order the agent signs.
contract CommitmentParityTest is Test {
    UniswapRoutingVault vault;
    MorphoSupplyAdapter adapter;

    address constant AGENT  = 0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1;
    address constant USDC   = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address constant WETH   = 0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242;
    address constant WBTC   = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
    address constant ORACLE = 0xff07261c87763cc5693ab78746d0b6735Ec626F5;
    address constant IRM    = 0x09475a3D6eA8c314c592b1a3799bDE044E2F400F;

    bytes32 constant GOLDEN_ROUTE =
        0x1550425afc1bd6e48461c9d548abc3ee4de631f1109ac4feb5b971781f6efbb6;
    bytes32 constant GOLDEN_SUPPLY =
        0xbf3bd84489e1c4039990ab28cee4eb56baffe9065d7258a5ae534f7b5928a6db;

    function setUp() public {
        AuditAnchorV2 anchor = new AuditAnchorV2();
        address[] memory tokens = new address[](2);
        tokens[0] = USDC; tokens[1] = WETH;
        uint24[] memory fees = new uint24[](2);
        fees[0] = 3000; fees[1] = 500;
        vault = new UniswapRoutingVault(address(0xAAA1), address(0xBBB2), address(anchor), tokens, fees);

        bytes32[] memory markets = new bytes32[](1);
        markets[0] = keccak256(abi.encode(_market()));
        address[] memory loans = new address[](1);
        loans[0] = USDC;
        adapter = new MorphoSupplyAdapter(address(0xCCC3), address(anchor), loans, markets);
    }

    function _market() internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken:       USDC,
            collateralToken: WBTC,
            oracle:          ORACLE,
            irm:             IRM,
            lltv:            860000000000000000
        });
    }

    function test_RouteCommitmentMatchesPythonAndCast() public view {
        address[] memory t = new address[](2); t[0] = USDC;   t[1] = WETH;
        uint24[]  memory f = new uint24[](2);  f[0] = 3000;   f[1] = 500;
        uint16[]  memory w = new uint16[](2);  w[0] = 6000;   w[1] = 4000;
        uint256[] memory m = new uint256[](2); m[0] = 211166; m[1] = 5000;

        assertEq(
            vault.routeCommitment(AGENT, t, f, w, 1e18, m, 1893456000),
            GOLDEN_ROUTE,
            "Solidity routeCommitment diverged from the Python/cast golden"
        );
    }

    function test_SupplyCommitmentMatchesPythonAndCast() public view {
        assertEq(
            adapter.supplyCommitment(AGENT, _market(), 2271),
            GOLDEN_SUPPLY,
            "Solidity supplyCommitment diverged from the Python/cast golden"
        );
    }

    /// The two commitment families share one `execCommitmentOf` slot, so they
    /// must never collide even on identical-looking inputs.
    function test_RouteAndSupplyCommitmentsAreDisjoint() public view {
        assertTrue(GOLDEN_ROUTE != GOLDEN_SUPPLY, "commitment families collided");
    }
}
