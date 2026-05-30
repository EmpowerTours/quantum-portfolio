// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { WMON } from "../src/dex/WMON.sol";
import { MockToken } from "../src/dex/MockToken.sol";
import { MiniAMM } from "../src/dex/MiniAMM.sol";
import { RoutingVault } from "../src/RoutingVault.sol";

/// @notice Deploy the full mini-DEX stack on Monad testnet (chainId 10143):
///         WMON, two MockTokens (mUSDC + mUSDT), two MiniAMM pairs, a
///         RoutingVault, then seeds initial liquidity into both pairs.
/// @dev    Run on testnet:
///           forge script script/DeployDex.s.sol:DeployDex \
///             --rpc-url $MONAD_TESTNET_RPC --broadcast --legacy --verify \
///             --verifier etherscan --etherscan-api-key $MONADSCAN_API_KEY \
///             --verifier-url "https://api.etherscan.io/v2/api?chainid=10143"
contract DeployDex is Script {
    uint256 constant LP_MON_PER_PAIR = 1 ether;        // 1 MON per pair as testnet LP
    uint256 constant LP_TOKEN_PER_PAIR = 2_500 ether;  // 2,500 token units per pair

    function run() external returns (
        address wmon, address usdc, address usdt,
        address pairUsdc, address pairUsdt, address vault
    ) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        WMON wm = new WMON();
        MockToken u = new MockToken("Test USDC (Monad)", "mUSDC", 18);
        MockToken t = new MockToken("Test USDT (Monad)", "mUSDT", 18);
        MiniAMM pu = new MiniAMM(address(wm), address(u));
        MiniAMM pt = new MiniAMM(address(wm), address(t));
        RoutingVault rv = new RoutingVault(payable(address(wm)));

        // Seed: mint test tokens, wrap MON, add liquidity to both pairs.
        u.faucet(LP_TOKEN_PER_PAIR);
        t.faucet(LP_TOKEN_PER_PAIR);
        wm.deposit{value: LP_MON_PER_PAIR * 2}();

        u.approve(address(pu), type(uint256).max);
        wm.approve(address(pu), type(uint256).max);
        (uint256 amount0Usdc, uint256 amount1Usdc) =
            address(wm) < address(u)
                ? (LP_MON_PER_PAIR, LP_TOKEN_PER_PAIR)
                : (LP_TOKEN_PER_PAIR, LP_MON_PER_PAIR);
        pu.addLiquidity(amount0Usdc, amount1Usdc, deployer);

        t.approve(address(pt), type(uint256).max);
        wm.approve(address(pt), type(uint256).max);
        (uint256 amount0Usdt, uint256 amount1Usdt) =
            address(wm) < address(t)
                ? (LP_MON_PER_PAIR, LP_TOKEN_PER_PAIR)
                : (LP_TOKEN_PER_PAIR, LP_MON_PER_PAIR);
        pt.addLiquidity(amount0Usdt, amount1Usdt, deployer);

        vm.stopBroadcast();

        return (address(wm), address(u), address(t),
                address(pu), address(pt), address(rv));
    }
}
