// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { MonadAllocationVault } from "../src/MonadAllocationVault.sol";

/// @notice Deploy MonadAllocationVault to Monad (testnet 10143 or mainnet 143).
/// @dev    Reads DEPLOYER_PRIVATE_KEY from the environment.
///         Run on testnet:
///           forge script script/DeployVault.s.sol:DeployVault \
///             --rpc-url $MONAD_TESTNET_RPC --broadcast --legacy --verify \
///             --verifier etherscan --etherscan-api-key $MONADSCAN_API_KEY \
///             --verifier-url "https://api.etherscan.io/v2/api?chainid=10143"
///         For mainnet, swap RPC to https://rpc.monad.xyz and chainid=143 —
///         but only after a Santander prize event funds production deploy.
contract DeployVault is Script {
    function run() external returns (MonadAllocationVault vault) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        vault = new MonadAllocationVault();
        vm.stopBroadcast();
    }
}
