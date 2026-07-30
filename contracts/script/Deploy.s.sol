// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { AuditAnchor } from "../src/AuditAnchor.sol";

/// @notice Deploy AuditAnchor to Monad (testnet 10143 or mainnet 143).
/// @dev    Reads DEPLOYER_PRIVATE_KEY from the environment.
///         Testnet deployment (2026-05-29): 0x0e649C383CFA6be1998445D0A7a8E1cc7540D239
///         Monadscan: https://testnet.monadscan.com/address/0x0e649c383cfa6be1998445d0a7a8e1cc7540d239
///         Run:
///           forge script script/Deploy.s.sol:DeployAuditAnchor \
///             --rpc-url $MONAD_TESTNET_RPC --broadcast --legacy --verify \
///             --verifier etherscan --etherscan-api-key $MONADSCAN_API_KEY \
///             --verifier-url "https://api.etherscan.io/v2/api?chainid=10143"
///         For mainnet, swap RPC to https://rpc.monad.xyz and chainid=143 —
///         but only after a Santander prize event funds production deploy.
contract DeployAuditAnchor is Script {
    function run() external returns (AuditAnchor anchor) {
        // SUPERSEDED. The V2 executors call `execCommitmentOf`, which V1 does
        // not implement, so a vault wired to a V1 anchor is immutably bricked.
        // This script stayed reachable and unguarded, which made it the most
        // likely thing to actually go wrong on deploy day. Use
        // script/DeployAuditAnchorV2.s.sol. (Audit RT09.)
        require(
            vm.envOr("DEPLOY_LEGACY_V1_ANCHOR", false),
            "AuditAnchor V1 is superseded - use DeployAuditAnchorV2.s.sol "
            "(set DEPLOY_LEGACY_V1_ANCHOR=true only to reproduce history)"
        );
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        anchor = new AuditAnchor();
        vm.stopBroadcast();
        // Emit so the broadcast log captures the address even if stdout
        // is piped away. The deployed address is also written to
        // contracts/broadcast/Deploy.s.sol/<chainid>/run-latest.json.
    }
}
