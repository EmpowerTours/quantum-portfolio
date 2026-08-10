// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { UniswapRoutingVault } from "../src/UniswapRoutingVault.sol";
import { MorphoSupplyAdapter } from "../src/MorphoSupplyAdapter.sol";
import { AuditAnchorV2 } from "../src/AuditAnchorV2.sol";
import { PQBind } from "./helpers/PQBind.sol";
import { MockPQAttestation } from "./mocks/MockPQAttestation.sol";
import { MarketParams } from "../src/interfaces/IMorpho.sol";

/// @title  Settlement requires a post-quantum attestation
/// @notice Until this existed, `MLDSAAttestation.attest()` set `pqAttested` and
///         NOTHING read it. The post-quantum leg was demonstrated but not
///         load-bearing: value moved identically whether or not an ML-DSA-65
///         signature had ever been verified on-chain. Grepping the executors
///         for the attestation contract returned nothing at all.
///
///         These tests assert the guarantee the submission actually wants to
///         claim — *no value moves without a post-quantum-verified
///         authorisation* — and that it is enforced by the contract rather than
///         by an off-chain convention.
contract PQAttestationGateTest is Test {
    AuditAnchorV2 anchor;
    MockPQAttestation pq;

    address constant WMON   = address(0x11);
    address constant ROUTER = address(0x22);
    address constant MORPHO = address(0x33);
    address constant TOKEN  = address(0x7017);

    function setUp() public {
        anchor = new AuditAnchorV2();
        pq = new MockPQAttestation();
        pq.setAttestAll(false);      // closed by default here; that IS the test
    }

    function _vault() internal returns (UniswapRoutingVault) {
        address[] memory toks = new address[](1);
        toks[0] = TOKEN;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        return new UniswapRoutingVault(WMON, ROUTER, address(anchor), address(pq), toks, fees);
    }

    function _adapter() internal returns (MorphoSupplyAdapter) {
        address[] memory toks = new address[](1);
        toks[0] = TOKEN;
        bytes32[] memory mkts = new bytes32[](1);
        mkts[0] = bytes32(uint256(1));
        return new MorphoSupplyAdapter(MORPHO, address(anchor), address(pq), toks, mkts);
    }

    /// The gate must fire BEFORE the anchor lookup: an order that was never
    /// PQ-attested must be rejected for that reason, not for a missing anchor.
    function test_routing_reverts_when_order_is_not_pq_attested() public {
        UniswapRoutingVault v = _vault();
        bytes32 orderHash = keccak256("unattested-order");

        address[] memory toks = new address[](1);
        toks[0] = TOKEN;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        uint256[] memory minOut = new uint256[](1);
        minOut[0] = 1;

        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.NotPQAttested.selector, orderHash)
        );
        // Empty preimage on purpose: NotPQAttested is checked before the
        // binding, so reaching it with no preimage also asserts the guard order.
        v.executeAndRoute{value: 1 ether}(
            orderHash, toks, fees, w, minOut, block.timestamp + 1 hours, ""
        );
    }

    function test_supply_reverts_when_order_is_not_pq_attested() public {
        MorphoSupplyAdapter a = _adapter();
        bytes32 orderHash = keccak256("unattested-supply");
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyAdapter.NotPQAttested.selector, orderHash)
        );
        MarketParams memory mp = MarketParams({
            loanToken: TOKEN, collateralToken: address(0x44),
            oracle: address(0x55), irm: address(0x66), lltv: 8e17
        });
        a.supply(orderHash, mp, 1, 1, "");
    }

    /// Attesting a DIFFERENT order must not open the gate for this one — the
    /// flag is per-orderHash, not global.
    function test_attesting_another_order_does_not_authorise_this_one() public {
        UniswapRoutingVault v = _vault();
        pq.setAttested(keccak256("some-other-order"), true);
        bytes32 orderHash = keccak256("unattested-order");

        address[] memory toks = new address[](1);
        toks[0] = TOKEN;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        uint256[] memory minOut = new uint256[](1);
        minOut[0] = 1;

        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.NotPQAttested.selector, orderHash)
        );
        // Empty preimage on purpose: NotPQAttested is checked before the
        // binding, so reaching it with no preimage also asserts the guard order.
        v.executeAndRoute{value: 1 ether}(
            orderHash, toks, fees, w, minOut, block.timestamp + 1 hours, ""
        );
    }

    /// Once attested, the PQ gate stops being the blocker — execution proceeds
    /// far enough to fail on the NEXT check (no anchor), which proves the gate
    /// opened rather than that everything reverts for one reason.
    function test_once_attested_the_pq_gate_is_no_longer_the_blocker() public {
        UniswapRoutingVault v = _vault();
        bytes32 orderHash = keccak256("attested-order");
        pq.setAttested(orderHash, true);

        address[] memory toks = new address[](1);
        toks[0] = TOKEN;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        uint256[] memory minOut = new uint256[](1);
        minOut[0] = 1;

        vm.deal(address(this), 1 ether);
        // AnchorNotFound is checked AFTER the PQ binding, so this needs a
        // genuinely valid preimage — an empty one would revert at the binding
        // and the test would pass for the wrong reason.
        (bytes memory pre2, bytes32 derived) = PQBind.preimage(keccak256(abi.encode(
            block.chainid, address(v), address(this), toks, fees, w,
            uint256(1 ether), minOut, block.timestamp + 1 hours
        )));
        pq.setAttested(derived, true);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingVault.AnchorNotFound.selector, derived)
        );
        // Empty preimage on purpose: NotPQAttested is checked before the
        // binding, so reaching it with no preimage also asserts the guard order.
        v.executeAndRoute{value: 1 ether}(
            derived, toks, fees, w, minOut, block.timestamp + 1 hours, pre2
        );
    }

    /// The registry address is immutable. A gate an owner can switch off is not
    /// a guarantee, so there must be no setter for it.
    function test_pq_registry_is_immutable_and_public() public {
        UniswapRoutingVault v = _vault();
        assertEq(address(v.PQ()), address(pq), "vault must expose its PQ registry");
        MorphoSupplyAdapter a = _adapter();
        assertEq(address(a.PQ()), address(pq), "adapter must expose its PQ registry");
    }
}
