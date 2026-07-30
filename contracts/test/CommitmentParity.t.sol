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

    /// Commitments are now domain-separated by (block.chainid, address(this)),
    /// so a golden is only meaningful for a FIXED chain id and executor
    /// address. `vm.chainId` + `vm.etch` pin both, which is why the addresses
    /// below are constants rather than whatever CREATE happens to produce.
    uint256 constant GOLDEN_CHAIN_ID = 143;
    address constant GOLDEN_VAULT   = 0x00000000000000000000000000000000000000AA;
    address constant GOLDEN_ADAPTER = 0x00000000000000000000000000000000000000bb;

    /// The commitment also binds its own orderHash: `consumed` is keyed by
    /// orderHash, so a commitment that did not name its order could be filed
    /// under unlimited distinct orderHashes and executed once under each.
    bytes32 constant GOLDEN_ORDER_HASH =
        0x1111111111111111111111111111111111111111111111111111111111111111;

    bytes32 constant GOLDEN_ROUTE =
        0x40fb62c19118b6aa2413dbbd0721005b61847a02bd7a7c7e4c5bb862ffb183ba;
    bytes32 constant GOLDEN_SUPPLY =
        0xc51ff91d917e16305fef7efe869fc222ba736e34ae0608730ad96d217f268a6e;

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

        // Pin chain id and executor addresses so the goldens are reproducible.
        vm.chainId(GOLDEN_CHAIN_ID);
        vm.etch(GOLDEN_VAULT, address(vault).code);
        vm.etch(GOLDEN_ADAPTER, address(adapter).code);
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
            UniswapRoutingVault(payable(GOLDEN_VAULT))
                .routeCommitment(GOLDEN_ORDER_HASH, AGENT, t, f, w, 1e18, m, 1893456000),
            GOLDEN_ROUTE,
            "Solidity routeCommitment diverged from the Python/cast golden"
        );
    }

    function test_SupplyCommitmentMatchesPythonAndCast() public view {
        assertEq(
            MorphoSupplyAdapter(GOLDEN_ADAPTER).supplyCommitment(GOLDEN_ORDER_HASH, AGENT, _market(), 2271),
            GOLDEN_SUPPLY,
            "Solidity supplyCommitment diverged from the Python/cast golden"
        );
    }

    /// The two commitment families share one `execCommitmentOf` slot, so they
    /// must never collide even on identical-looking inputs.
    function test_RouteAndSupplyCommitmentsAreDisjoint() public pure {
        assertTrue(GOLDEN_ROUTE != GOLDEN_SUPPLY, "commitment families collided");
    }

    /// Domain separation: the SAME arguments on a DIFFERENT vault must yield a
    /// different commitment. Without this, one anchor was spendable once on
    /// every vault sharing the anchor — `consumed` is per-executor storage.
    function test_CommitmentIsBoundToTheExecutorAddress() public {
        address[] memory t = new address[](2); t[0] = USDC;   t[1] = WETH;
        uint24[]  memory f = new uint24[](2);  f[0] = 3000;   f[1] = 500;
        uint16[]  memory w = new uint16[](2);  w[0] = 6000;   w[1] = 4000;
        uint256[] memory m = new uint256[](2); m[0] = 211166; m[1] = 5000;

        address other = address(0x00000000000000000000000000000000000000cc);
        vm.etch(other, address(vault).code);
        assertTrue(
            UniswapRoutingVault(payable(other)).routeCommitment(GOLDEN_ORDER_HASH, AGENT, t, f, w, 1e18, m, 1893456000)
                != GOLDEN_ROUTE,
            "commitment must differ across vault deployments"
        );
    }

    /// ...and the same arguments under a different ORDER HASH must differ,
    /// which is what stops one authorisation being spent under many orders.
    function test_CommitmentIsBoundToTheOrderHash() public view {
        address[] memory t = new address[](2); t[0] = USDC;   t[1] = WETH;
        uint24[]  memory f = new uint24[](2);  f[0] = 3000;   f[1] = 500;
        uint16[]  memory w = new uint16[](2);  w[0] = 6000;   w[1] = 4000;
        uint256[] memory m = new uint256[](2); m[0] = 211166; m[1] = 5000;

        assertTrue(
            UniswapRoutingVault(payable(GOLDEN_VAULT))
                .routeCommitment(keccak256("a-different-order"), AGENT, t, f, w,
                                 1e18, m, 1893456000) != GOLDEN_ROUTE,
            "commitment must differ across orderHashes"
        );
    }

    /// ...and the same arguments on a different CHAIN must differ too.
    function test_CommitmentIsBoundToTheChainId() public {
        address[] memory t = new address[](2); t[0] = USDC;   t[1] = WETH;
        uint24[]  memory f = new uint24[](2);  f[0] = 3000;   f[1] = 500;
        uint16[]  memory w = new uint16[](2);  w[0] = 6000;   w[1] = 4000;
        uint256[] memory m = new uint256[](2); m[0] = 211166; m[1] = 5000;

        vm.chainId(10143);   // Monad testnet
        assertTrue(
            UniswapRoutingVault(payable(GOLDEN_VAULT))
                .routeCommitment(GOLDEN_ORDER_HASH, AGENT, t, f, w, 1e18, m, 1893456000) != GOLDEN_ROUTE,
            "commitment must differ across chains"
        );
    }
}
