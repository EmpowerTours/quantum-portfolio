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
///     APPROVED_TOKENS (comma-separated loan-token allowlist, e.g. USDC).
contract DeployMorphoSupplyAdapter is Script {
    address constant MORPHO_MAINNET = 0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee;

    function run() external returns (address adapter) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address anchor = vm.envAddress("AUDIT_ANCHOR_ADDR");
        address[] memory approved = vm.envAddress("APPROVED_TOKENS", ",");
        require(approved.length > 0, "APPROVED_TOKENS empty");
        require(block.chainid == 143, "not Monad mainnet (chainId 143)");

        vm.startBroadcast(pk);
        MorphoSupplyAdapter a = new MorphoSupplyAdapter(MORPHO_MAINNET, anchor, approved);
        vm.stopBroadcast();

        console2.log("MorphoSupplyAdapter:", address(a));
        console2.log("  Morpho:", MORPHO_MAINNET);
        console2.log("  Anchor:", anchor);
        console2.log("  Approved loan tokens:", approved.length);
        return address(a);
    }
}
