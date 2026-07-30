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
        require(anchor.code.length > 0, "AUDIT_ANCHOR_ADDR has no code");
        // Identify the anchor by CAPABILITY, not by blacklisting one address.
        // The old check was `anchor != ANCHOR_MAINNET`, which any fresh V1
        // deployment trivially satisfies — and `script/Deploy.s.sol` deploys
        // V1. `execCommitmentOf` does not exist on V1 and V1 has no fallback,
        // so a staticcall that returns 32 bytes is a positive proof of V2.
        // (Audit RT09.)
        (bool probeOk, bytes memory probeRet) = anchor.staticcall(
            abi.encodeWithSignature(
                "execCommitmentOf(address,bytes32)", address(this), bytes32(0)
            )
        );
        require(
            probeOk && probeRet.length == 32,
            "AUDIT_ANCHOR_ADDR does not implement execCommitmentOf - not an AuditAnchorV2"
        );

        require(MORPHO_MAINNET.code.length > 0, "Morpho Blue has no code");
        for (uint256 i = 0; i < approved.length; ++i) {
            require(approved[i].code.length > 0, "APPROVED_TOKENS entry has no code");
        }
        // A non-zero market id is not a real market. An id that Morpho has
        // never heard of deploys a permanently bricked adapter, and one whose
        // loan token is outside APPROVED_TOKENS can never be supplied to.
        // Resolve each id against Morpho itself. (Audit RT09.)
        for (uint256 i = 0; i < markets.length; ++i) {
            require(markets[i] != bytes32(0), "APPROVED_MARKETS entry is zero");
            for (uint256 j = 0; j < i; ++j) {
                require(markets[j] != markets[i], "duplicate APPROVED_MARKETS entry");
            }
            (bool ok, bytes memory ret) = MORPHO_MAINNET.staticcall(
                abi.encodeWithSignature("idToMarketParams(bytes32)", markets[i])
            );
            require(ok && ret.length >= 160, "market id not resolvable on Morpho");
            (address loanToken,,,,) =
                abi.decode(ret, (address, address, address, address, uint256));
            require(loanToken != address(0), "market id unknown to Morpho");
            bool loanApproved;
            for (uint256 k = 0; k < approved.length; ++k) {
                if (approved[k] == loanToken) { loanApproved = true; break; }
            }
            require(loanApproved, "market loan token is not in APPROVED_TOKENS");
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
