// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { AuditAnchorV2 }    from "../src/AuditAnchorV2.sol";

/// @notice Deploy AuditAnchorV2 — the anchor the V2 executors REQUIRE.
///
/// @dev    This script exists because its absence was a deployment blocker.
///         `script/Deploy.s.sol` deploys V1 `AuditAnchor` and has no chainId
///         guard at all, so an operator told "deploy the anchor first" had
///         exactly one script to reach for and it produced the WRONG anchor.
///         The vault and adapter then deploy cleanly against it — every guard
///         passes for a fresh, code-bearing address — and every
///         `executeAndRoute` reverts forever inside `ANCHOR.execCommitmentOf`,
///         which V1 does not implement and has no fallback for. Immutable
///         anchor, no owner, no setter: the deployment is a write-off.
///         (Audit RT09.)
///
///         Deploy order is: this script, then DeployUniswapRoutingVault and
///         DeployMorphoSupplyAdapter with AUDIT_ANCHOR_ADDR set to the address
///         printed below. Those scripts probe for `execCommitmentOf` rather
///         than blacklisting the known V1 address, so pointing them at any
///         non-V2 contract now fails loudly instead of deploying a brick.
///
///     Usage (dry run — does NOT broadcast):
///       forge script script/DeployAuditAnchorV2.s.sol --rpc-url https://rpc.monad.xyz
///     Add --broadcast to send. Requires DEPLOYER_PRIVATE_KEY.
contract DeployAuditAnchorV2 is Script {
    function run() external returns (address anchor) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // V1's script had no chain guard, which is how a mainnet-intended
        // deploy could silently land somewhere else.
        require(block.chainid == 143, "not Monad mainnet (chainId 143)");

        vm.startBroadcast(pk);
        AuditAnchorV2 a = new AuditAnchorV2();
        vm.stopBroadcast();

        // Self-check: the executors identify a V2 anchor by this selector
        // responding. Prove it does before anyone wires an immutable to it.
        // Keyed on `address(0)` — forge rejects `address(this)` in a script.
        require(a.execCommitmentOf(address(0), bytes32(0)) == bytes32(0), "probe failed");

        console2.log("AuditAnchorV2:", address(a));
        console2.log("  -> set AUDIT_ANCHOR_ADDR to this for the vault + adapter");
        return address(a);
    }
}
