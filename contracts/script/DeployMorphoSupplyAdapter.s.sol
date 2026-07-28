// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { MorphoSupplyAdapter } from "../src/MorphoSupplyAdapter.sol";

/// @notice Deploy MorphoSupplyAdapter wired to Morpho Blue on Monad mainnet.
///
///         Morpho Blue (Monad mainnet, chainId 143):
///           0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee
///
///     Usage (dry run):
///       forge script script/DeployMorphoSupplyAdapter.s.sol --rpc-url https://rpc.monad.xyz
///     Add --broadcast to send. Requires DEPLOYER_PRIVATE_KEY, AUDIT_ANCHOR_ADDR,
///     APPROVED_TOKENS (comma-separated loan-token allowlist, e.g. USDC), and
///     APPROVED_MARKETS (comma-separated Morpho market ids, e.g. the funded
///     USDC/WBTC market 0xe35c5abc6418b6319b014e07aa3c86163a870a957284128f03cf7a9e414f8899).
///
/// @dev Every constructor argument is immutable or frozen at deploy, so a
///      typo'd env var yields a permanently broken contract. The guards below
///      assert each address actually carries code before broadcasting.
///      (Audit N-1.)
contract DeployMorphoSupplyAdapter is Script {
    address constant MORPHO_MAINNET = 0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee;
    address constant ANCHOR_MAINNET = 0x4cB79cc36b367A6fd7363BC6a8553a7A270DA27c;

    function run() external returns (address adapter) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address anchor = vm.envAddress("AUDIT_ANCHOR_ADDR");
        address[] memory approved = vm.envAddress("APPROVED_TOKENS", ",");
        bytes32[] memory markets = vm.envBytes32("APPROVED_MARKETS", ",");

        require(block.chainid == 143, "not Monad mainnet (chainId 143)");
        require(approved.length > 0, "APPROVED_TOKENS empty");
        require(markets.length > 0, "APPROVED_MARKETS empty");

        // N-1: validate every address wired in immutably.
        // NOTE: AuditAnchorV2 is a NEW deployment; set AUDIT_ANCHOR_ADDR to it.
        require(anchor != ANCHOR_MAINNET, "AUDIT_ANCHOR_ADDR is the V1 anchor; deploy V2 first");
        require(anchor.code.length > 0, "AUDIT_ANCHOR_ADDR has no code");
        require(MORPHO_MAINNET.code.length > 0, "Morpho Blue has no code");
        for (uint256 i = 0; i < approved.length; ++i) {
            require(approved[i].code.length > 0, "APPROVED_TOKENS entry has no code");
        }
        for (uint256 i = 0; i < markets.length; ++i) {
            require(markets[i] != bytes32(0), "APPROVED_MARKETS entry is zero");
        }

        vm.startBroadcast(pk);
        MorphoSupplyAdapter a =
            new MorphoSupplyAdapter(MORPHO_MAINNET, anchor, approved, markets);
        vm.stopBroadcast();

        console2.log("MorphoSupplyAdapter:", address(a));
        console2.log("  Morpho:", MORPHO_MAINNET);
        console2.log("  Anchor:", anchor);
        console2.log("  Approved loan tokens:", approved.length);
        console2.log("  Approved markets:", markets.length);
        return address(a);
    }
}
