// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MLDSAAttestation, PublicValuesStruct} from "../src/MLDSAAttestation.sol";

/// @notice Deploy MLDSAAttestation and PROVE it works before you trust it.
///
/// @dev    This script exists because its absence was the highest-consequence
///         manual step in the whole deployment. `verifier`, `mldsaProgramVKey`
///         and `agentPkHash` are all immutable with no owner and no setter, so
///         a single wrong value is a permanent write-off — and the failure is
///         silent at deploy time, surfacing only when `attest()` reverts.
///
///         That is not hypothetical. The shipped fixture proved a signature by
///         ML-DSA key `8a1b08d1…`, whose secret half was lost; its
///         `publicValues` was 32 bytes where the contract decodes 64; and it
///         carried the superseded vkey `0x00eddc1f…`. Deploying against any of
///         those would have produced a contract that could never attest
///         anything.
///
///         So this script cross-checks the fixture against the environment
///         BEFORE broadcasting, and then calls `isValidProof` against the
///         freshly deployed contract AFTER. If the post-deploy check passes,
///         the deployment is known-good rather than assumed-good.
///
///     Usage (dry run — does NOT broadcast):
///       forge script script/DeployMLDSAAttestation.s.sol --rpc-url https://rpc.monad.xyz
///     Add --broadcast to send. Requires:
///       DEPLOYER_PRIVATE_KEY  deployer key
///       SP1_VERIFIER          SP1 Groth16 verifier / gateway on Monad mainnet
///       AGENT_PK_HASH         SHA-256 of keys/pq.pub
///       FIXTURE_PATH          path to the groth16 fixture JSON (default below)
contract DeployMLDSAAttestation is Script {
    function run() external returns (address attestation) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address verifier = vm.envAddress("SP1_VERIFIER");
        bytes32 agentPkHash = vm.envBytes32("AGENT_PK_HASH");
        string memory fixturePath = vm.envOr(
            "FIXTURE_PATH",
            string.concat(vm.projectRoot(), "/src/fixtures/groth16-mldsa-fixture.json")
        );

        require(block.chainid == 143, "not Monad mainnet (chainId 143)");
        require(verifier.code.length > 0, "SP1_VERIFIER has no code");
        require(agentPkHash != bytes32(0), "AGENT_PK_HASH unset");

        // --- read the fixture the deployment will be validated against ------
        string memory json = vm.readFile(fixturePath);
        bytes32 vkey = vm.parseJsonBytes32(json, ".vkey");
        bytes memory publicValues = vm.parseJsonBytes(json, ".publicValues");
        bytes memory proof = vm.parseJsonBytes(json, ".proof");

        require(vkey != bytes32(0), "fixture vkey is zero");
        require(proof.length > 0, "fixture proof is empty");

        // The guest commits (orderHash, pkHash) — two words. A 32-byte
        // publicValues is the OLD single-field layout and would revert inside
        // abi.decode, after the verifier has already been paid for.
        require(
            publicValues.length == 64,
            "fixture publicValues is not 64 bytes - stale single-field layout"
        );

        PublicValuesStruct memory pv = abi.decode(publicValues, (PublicValuesStruct));

        // The fixture must prove a signature by the key we are pinning.
        // Without this the contract deploys cleanly and reverts UnknownSigner
        // on every call, forever.
        require(
            pv.pkHash == agentPkHash,
            "fixture was signed by a DIFFERENT key than AGENT_PK_HASH"
        );

        console2.log("Fixture pre-flight OK");
        console2.log("  vkey:      ", vm.toString(vkey));
        console2.log("  orderHash: ", vm.toString(pv.orderHash));
        console2.log("  pkHash:    ", vm.toString(pv.pkHash));

        vm.startBroadcast(pk);
        MLDSAAttestation a = new MLDSAAttestation(verifier, vkey, agentPkHash);
        vm.stopBroadcast();

        // --- post-deploy: prove the thing actually attests ------------------
        // A staticcall, so it records nothing. If this reverts, the deployed
        // contract is a brick and you know NOW, not on first real use.
        bytes32 got = a.isValidProof(publicValues, proof);
        require(got == pv.orderHash, "post-deploy isValidProof returned the wrong orderHash");

        console2.log("MLDSAAttestation:", address(a));
        console2.log("  verifier:", verifier);
        console2.log("  post-deploy isValidProof: PASSED (proof verifies on-chain)");
        return address(a);
    }
}
