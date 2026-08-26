// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MLDSAAttestationV2, PublicValuesStruct} from "../src/MLDSAAttestationV2.sol";

/// @notice Deploy MLDSAAttestationV2 and PROVE it works before you trust it.
///
/// @dev    Same discipline as `DeployMLDSAAttestation.s.sol` — cross-check the
///         fixture against the environment BEFORE broadcasting, then call
///         `isValidProof` against the freshly deployed contract AFTER — plus
///         the checks the rotation path adds.
///
///         WHAT MOVES WHEN THIS SHIPS. `PQ()` is `immutable` on both
///         executors, so pointing them at a new attestation address means
///         redeploying UniswapRoutingVault and MorphoSupplyAdapter too. That
///         is the last time it should be necessary: after this, the agent key
///         changes by signing, not by redeploying.
///
///     Usage (dry run — simulates only):
///       forge script script/DeployMLDSAAttestationV2.s.sol --rpc-url https://rpc.monad.xyz
///     A human adds the broadcast flag to send. Requires:
///       DEPLOYER_PRIVATE_KEY  deployer key (OR pass --account deployer --sender)
///       SP1_VERIFIER          SP1 Groth16 verifier / gateway on Monad mainnet
///       AGENT_PK_HASH         SHA-256 of keys/pq.pub
///       GUARDIAN              recovery authority — prefer a multisig
///       RECOVERY_DELAY        seconds, 2-30 days (default 7 days)
///       FIXTURE_PATH          path to the groth16 fixture JSON (default below)
contract DeployMLDSAAttestationV2 is Script {
    function run() external returns (address attestation) {
        // Match the executor scripts: prefer the encrypted forge keystore
        // (`--account deployer`), which keeps the key out of the process
        // environment entirely, and fall back to DEPLOYER_PRIVATE_KEY when it
        // is set. With neither, forge refuses rather than using its default
        // sender.
        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address verifier = vm.envAddress("SP1_VERIFIER");
        bytes32 agentPkHash = vm.envBytes32("AGENT_PK_HASH");
        address guardian = vm.envAddress("GUARDIAN");
        uint64 delay = uint64(vm.envOr("RECOVERY_DELAY", uint256(7 days)));
        string memory fixturePath = vm.envOr(
            "FIXTURE_PATH",
            string.concat(vm.projectRoot(), "/src/fixtures/groth16-mldsa-fixture.json")
        );

        require(block.chainid == 143, "not Monad mainnet (chainId 143)");
        require(verifier.code.length > 0, "SP1_VERIFIER has no code");
        require(agentPkHash != bytes32(0), "AGENT_PK_HASH unset");
        require(guardian != address(0), "GUARDIAN unset");

        // A guardian that IS the deployer's hot key is a strict downgrade: the
        // key that broadcasts every transaction would also hold the recovery
        // authority, so one compromise reaches both. The whole point of the
        // split is that they fail independently.
        address deployer = pk != 0 ? vm.addr(pk) : msg.sender;
        require(guardian != deployer, "GUARDIAN must not be the deployer key");

        // Fail on the WRONG KEY before anything is signed. Without this, a key
        // for a different account deploys happily from an address nobody
        // expected, and the mistake is only visible afterwards in the receipt.
        // Set EXPECTED_DEPLOYER to assert which account must sign.
        address expected = vm.envOr("EXPECTED_DEPLOYER", address(0));
        require(
            expected == address(0) || deployer == expected,
            "signing key does not match EXPECTED_DEPLOYER"
        );

        // A guardian with no code, no balance and no history is a typo, and
        // the consequence of that typo is a recovery path that does not exist
        // — discovered on the day it is needed, which is the worst possible
        // day. Every real account fails at least one of these three.
        require(
            guardian.code.length > 0 || guardian.balance > 0 || vm.getNonce(guardian) > 0,
            "GUARDIAN has no code, no balance and no nonce - typo?"
        );

        if (guardian.code.length == 0) {
            console2.log("WARNING: GUARDIAN is an EOA, not a multisig/timelock.");
            console2.log("         Recovery authority sits behind a single secp256k1 key.");
            console2.log("         The delay bounds the damage only if somebody is WATCHING:");
            console2.log("         alert on RecoveryProposed and veto within recoveryDelay.");
        }

        // --- read the fixture the deployment will be validated against ------
        string memory json = vm.readFile(fixturePath);
        bytes32 vkey = vm.parseJsonBytes32(json, ".vkey");
        bytes memory publicValues = vm.parseJsonBytes(json, ".publicValues");
        bytes memory proof = vm.parseJsonBytes(json, ".proof");

        require(vkey != bytes32(0), "fixture vkey is zero");
        require(proof.length > 0, "fixture proof is empty");
        require(
            publicValues.length == 64,
            "fixture publicValues is not 64 bytes - stale single-field layout"
        );

        PublicValuesStruct memory pv = abi.decode(publicValues, (PublicValuesStruct));
        require(
            pv.pkHash == agentPkHash,
            "fixture was signed by a DIFFERENT key than AGENT_PK_HASH"
        );

        console2.log("Fixture pre-flight OK");
        console2.log("  vkey:      ", vm.toString(vkey));
        console2.log("  orderHash: ", vm.toString(pv.orderHash));
        console2.log("  pkHash:    ", vm.toString(pv.pkHash));

        if (pk != 0) { vm.startBroadcast(pk); } else { vm.startBroadcast(); }
        MLDSAAttestationV2 a =
            new MLDSAAttestationV2(verifier, vkey, agentPkHash, guardian, delay);
        vm.stopBroadcast();

        // --- post-deploy: prove the thing actually attests ------------------
        bytes32 got = a.isValidProof(publicValues, proof);
        require(got == pv.orderHash, "post-deploy isValidProof returned the wrong orderHash");

        // --- post-deploy: prove the rotation path is actually reachable -----
        // A deployment whose recovery authority is wrong is a deployment with
        // no recovery authority, which is the v1 state this replaces.
        require(a.isAgentPk(agentPkHash), "genesis key not authorised");
        require(a.agentPkCount() == 1, "unexpected authorised-key count");
        require(a.guardian() == guardian, "guardian not set");
        require(a.recoveryDelay() == delay, "recoveryDelay not set");
        require(a.rotationNonce() == 0, "rotationNonce not zero");
        require(a.pendingPkHash() == bytes32(0), "unexpected pending recovery");

        console2.log("MLDSAAttestationV2:", address(a));
        console2.log("  verifier:", verifier);
        console2.log("  guardian:", guardian);
        console2.log("  recoveryDelay (s):", delay);
        console2.log("  post-deploy isValidProof: PASSED (proof verifies on-chain)");
        console2.log("");
        console2.log("NEXT: redeploy UniswapRoutingVault and MorphoSupplyAdapter with");
        console2.log("      PQ = this address. Their PQ() is immutable.");
        return address(a);
    }
}
