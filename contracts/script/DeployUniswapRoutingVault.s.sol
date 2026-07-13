// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { UniswapRoutingVault } from "../src/UniswapRoutingVault.sol";

/// @notice Deploy UniswapRoutingVault wired to the REAL Uniswap v3
///         SwapRouter02 on Monad mainnet (chainId 143).
///
///         Verified addresses (developers.uniswap.org, v3-monad-deployments;
///         docs.monad.xyz network-information), captured 2026-07-12:
///           WMON (wrapped native) 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A
///           SwapRouter02          0xfe31f71c1b106eac32f1a19239c9a9a72ddfb900
///
///         AuditAnchor (mainnet): 0x4cb79cc36b367a6fd7363bc6a8553a7a270da27c.
///         Pass its mainnet address via AUDIT_ANCHOR_ADDR once anchored.
///
///         The approved-token universe is passed via APPROVED_TOKENS (a
///         comma-separated env list of 0x addresses) so the tradable set is
///         reviewable at deploy time and frozen into the vault. Populate it
///         with the Monad-native DeFi tokens the agent's pool universe maps
///         to (e.g. bridged USDC/USDT, WETH, WBTC) once their mainnet
///         addresses + live v3 pools are confirmed.
///
///     Usage (dry run — does NOT broadcast):
///       forge script script/DeployUniswapRoutingVault.s.sol \
///         --rpc-url https://rpc.monad.xyz
///     Add --broadcast to send. Requires DEPLOYER_PRIVATE_KEY,
///     AUDIT_ANCHOR_ADDR, APPROVED_TOKENS in the environment.
contract DeployUniswapRoutingVault is Script {
    address constant WMON_MAINNET   = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant ROUTER_MAINNET = 0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900;

    function run() external returns (address vault) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address anchor = vm.envAddress("AUDIT_ANCHOR_ADDR");
        address[] memory approved = vm.envAddress("APPROVED_TOKENS", ",");
        require(approved.length > 0, "APPROVED_TOKENS empty");

        require(block.chainid == 143, "not Monad mainnet (chainId 143)");

        vm.startBroadcast(pk);
        UniswapRoutingVault v = new UniswapRoutingVault(
            WMON_MAINNET, ROUTER_MAINNET, anchor, approved
        );
        vm.stopBroadcast();

        console2.log("UniswapRoutingVault:", address(v));
        console2.log("  WMON:  ", WMON_MAINNET);
        console2.log("  Router:", ROUTER_MAINNET);
        console2.log("  Anchor:", anchor);
        console2.log("  Approved tokens:", approved.length);
        return address(v);
    }
}
