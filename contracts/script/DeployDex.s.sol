// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { WMON } from "../src/dex/WMON.sol";
import { MockToken } from "../src/dex/MockToken.sol";
import { MiniAMM } from "../src/dex/MiniAMM.sol";
import { RoutingVault } from "../src/RoutingVault.sol";
import { AuditAnchor } from "../src/AuditAnchor.sol";

/// @notice Deploy the hardened mini-DEX stack on Monad testnet (chainId 10143):
///         WMON + 2 MockTokens + 2 MiniAMM pairs + RoutingVault, all with
///         the audit-2 fixes. Reuses the existing AuditAnchor at the address
///         passed via env var AUDIT_ANCHOR_ADDR; if absent, deploys a fresh one.
contract DeployDex is Script {
    uint256 constant LP_MON_PER_PAIR   = 1 ether;
    uint256 constant LP_TOKEN_PER_PAIR = 2_500 ether;

    function run() external returns (
        address wmon, address usdc, address usdt,
        address pairUsdc, address pairUsdt, address vault, address anchor
    ) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Reuse the existing live AuditAnchor by default — env var lets
        // a fresh integration test point at its own anchor.
        address anchorAddr = vm.envOr(
            "AUDIT_ANCHOR_ADDR",
            address(0x0e649C383CFA6be1998445D0A7a8E1cc7540D239)
        );

        vm.startBroadcast(pk);

        AuditAnchor anchorContract;
        if (anchorAddr.code.length == 0) {
            anchorContract = new AuditAnchor();
            anchorAddr = address(anchorContract);
        } else {
            anchorContract = AuditAnchor(anchorAddr);
        }

        WMON wm = new WMON();
        MockToken u = new MockToken("Test USDC (Monad)", "mUSDC", 18);
        MockToken t = new MockToken("Test USDT (Monad)", "mUSDT", 18);
        MiniAMM pu = new MiniAMM(address(wm), address(u));
        MiniAMM pt = new MiniAMM(address(wm), address(t));

        address[] memory approvedPairs = new address[](2);
        approvedPairs[0] = address(pu);
        approvedPairs[1] = address(pt);
        RoutingVault rv = new RoutingVault(payable(address(wm)), anchorAddr, approvedPairs);

        // Seed liquidity into both pairs.
        u.faucet(LP_TOKEN_PER_PAIR);
        t.faucet(LP_TOKEN_PER_PAIR);
        wm.deposit{value: LP_MON_PER_PAIR * 2}();

        u.approve(address(pu), type(uint256).max);
        wm.approve(address(pu), type(uint256).max);
        (uint256 amount0Usdc, uint256 amount1Usdc) = address(wm) < address(u)
            ? (LP_MON_PER_PAIR, LP_TOKEN_PER_PAIR)
            : (LP_TOKEN_PER_PAIR, LP_MON_PER_PAIR);
        pu.addLiquidity(amount0Usdc, amount1Usdc, deployer);

        t.approve(address(pt), type(uint256).max);
        wm.approve(address(pt), type(uint256).max);
        (uint256 amount0Usdt, uint256 amount1Usdt) = address(wm) < address(t)
            ? (LP_MON_PER_PAIR, LP_TOKEN_PER_PAIR)
            : (LP_TOKEN_PER_PAIR, LP_MON_PER_PAIR);
        pt.addLiquidity(amount0Usdt, amount1Usdt, deployer);

        vm.stopBroadcast();

        return (address(wm), address(u), address(t),
                address(pu), address(pt), address(rv), anchorAddr);
    }
}
