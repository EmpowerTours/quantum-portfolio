// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MLDSAAttestationV2, PublicValuesStruct} from "../src/MLDSAAttestationV2.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";

/// @notice The rotation path for `agentPkHash`.
///
/// @dev    Every test here is about AUTHORISATION, not about lattice maths: the
///         verifier is mocked (see MockSP1Verifier for why). "Signing" a
///         statement in this suite means producing the public values the guest
///         would commit for that message — `(sha256(statement), sha256(pk))` —
///         which is exactly the interface the contract consumes.
contract MLDSAAttestationV2Test is Test {
    MockSP1Verifier verifier;
    MLDSAAttestationV2 att;

    bytes32 constant VKEY     = keccak256("vkey");
    bytes32 constant GENESIS  = keccak256("genesis-pk");
    bytes32 constant NEW_PK   = keccak256("new-pk");
    bytes32 constant THIRD_PK = keccak256("third-pk");
    address constant GUARDIAN = address(0x60A);
    uint64  constant DELAY    = 7 days;

    bytes constant PROOF = hex"1234";

    uint8 constant ADD    = 1;
    uint8 constant REVOKE = 2;
    uint8 constant VETO   = 3;

    function setUp() public {
        verifier = new MockSP1Verifier();
        att = new MLDSAAttestationV2(address(verifier), VKEY, GENESIS, GUARDIAN, DELAY);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev The public values the SP1 guest commits when `pk` signs the message
    ///      whose sha256 is `msgHash`.
    function _pv(bytes32 msgHash, bytes32 pk) internal pure returns (bytes memory) {
        return abi.encode(PublicValuesStruct({orderHash: msgHash, pkHash: pk}));
    }

    /// @dev Public values for `pk` signing the current reconfiguration statement.
    function _stmt(uint8 action, bytes32 subject, bytes32 pk) internal view returns (bytes memory) {
        return _pv(att.statementHash(action, subject, att.rotationNonce()), pk);
    }

    // ------------------------------------------------------------ constructor

    function test_constructor_authorisesGenesisKeyOnly() public view {
        assertTrue(att.isAgentPk(GENESIS));
        assertFalse(att.isAgentPk(NEW_PK));
        assertEq(att.agentPkCount(), 1);
        assertEq(att.genesisAgentPkHash(), GENESIS);
        assertEq(att.guardian(), GUARDIAN);
        assertEq(att.rotationNonce(), 0);
    }

    /// A deployment with no recovery authority reproduces the exact v1 failure
    /// this contract exists to remove, so it is rejected rather than defaulted.
    function test_constructor_rejectsZeroGuardian() public {
        vm.expectRevert("guardian unset");
        new MLDSAAttestationV2(address(verifier), VKEY, GENESIS, address(0), DELAY);
    }

    function test_constructor_rejectsDelayOutOfRange() public {
        vm.expectRevert("recoveryDelay out of range");
        new MLDSAAttestationV2(address(verifier), VKEY, GENESIS, GUARDIAN, 1 days);
        vm.expectRevert("recoveryDelay out of range");
        new MLDSAAttestationV2(address(verifier), VKEY, GENESIS, GUARDIAN, 31 days);
    }

    // -------------------------------------------------------------- attesting

    function test_attest_authorisedKey() public {
        bytes32 orderHash = keccak256("order-1");
        att.attest(_pv(orderHash, GENESIS), PROOF);
        assertTrue(att.pqAttested(orderHash));
        assertEq(att.attestedBy(orderHash), GENESIS);
    }

    function test_attest_rejectsUnauthorisedKey() public {
        vm.expectRevert(abi.encodeWithSelector(MLDSAAttestationV2.UnknownSigner.selector, NEW_PK));
        att.attest(_pv(keccak256("order-1"), NEW_PK), PROOF);
    }

    /// The verifier must run before the authorisation check, so an invalid
    /// proof cannot be used to probe which keys are authorised.
    function test_attest_rejectsInvalidProof() public {
        verifier.setAccept(false);
        vm.expectRevert(MockSP1Verifier.ProofRejected.selector);
        att.attest(_pv(keccak256("order-1"), GENESIS), PROOF);
    }

    function test_pqAttested_falseForUnknownOrder() public view {
        assertFalse(att.pqAttested(keccak256("never-attested")));
    }

    /// The executors call this contract through `IPQAttestation` at an
    /// `immutable` address they were deployed with. V2 turns `pqAttested` from
    /// a public mapping into a function, so pin the selector: if it ever
    /// changes, every executor pointed at this contract stops working and
    /// cannot be patched.
    function test_pqAttestedSelectorMatchesIPQAttestation() public pure {
        assertEq(
            MLDSAAttestationV2.pqAttested.selector,
            bytes4(keccak256("pqAttested(bytes32)"))
        );
    }

    // ---------------------------------------------------------------- PQ path

    function test_rotateAdd_authorisesNewKeyAndBothCanAttest() public {
        att.rotateAdd(NEW_PK, _stmt(ADD, NEW_PK, GENESIS), PROOF);

        assertTrue(att.isAgentPk(NEW_PK));
        assertTrue(att.isAgentPk(GENESIS));
        assertEq(att.agentPkCount(), 2);
        assertEq(att.rotationNonce(), 1);

        att.attest(_pv(keccak256("o-old"), GENESIS), PROOF);
        att.attest(_pv(keccak256("o-new"), NEW_PK), PROOF);
        assertTrue(att.pqAttested(keccak256("o-old")));
        assertTrue(att.pqAttested(keccak256("o-new")));
    }

    /// The whole rotation story fails if a signature over "add X" can be
    /// re-submitted to add X again later, or replayed after a revoke.
    function test_rotateAdd_statementIsSingleUse() public {
        bytes memory pv = _stmt(ADD, NEW_PK, GENESIS);
        att.rotateAdd(NEW_PK, pv, PROOF);
        vm.expectRevert(); // nonce consumed -> StatementMismatch
        att.rotateAdd(NEW_PK, pv, PROOF);
    }

    /// A statement signed against a different subject cannot be redirected: the
    /// contract recomputes the expected hash from the caller's own argument.
    function test_rotateAdd_rejectsSubjectSubstitution() public {
        bytes memory pv = _stmt(ADD, NEW_PK, GENESIS);
        vm.expectRevert();
        att.rotateAdd(THIRD_PK, pv, PROOF);
    }

    function test_rotateAdd_rejectsWrongAction() public {
        // A signature authorising REVOKE of NEW_PK must not add it.
        bytes memory pv = _stmt(REVOKE, NEW_PK, GENESIS);
        vm.expectRevert();
        att.rotateAdd(NEW_PK, pv, PROOF);
    }

    /// Chain id is inside the signed bytes, so a statement produced against a
    /// testnet deployment is inert on mainnet.
    function test_rotateAdd_rejectsCrossChainReplay() public {
        vm.chainId(10143);
        bytes memory pv = _stmt(ADD, NEW_PK, GENESIS);
        vm.chainId(143);
        vm.expectRevert();
        att.rotateAdd(NEW_PK, pv, PROOF);
    }

    function test_rotateAdd_rejectsUnauthorisedSigner() public {
        bytes memory pv = _stmt(ADD, THIRD_PK, NEW_PK);
        vm.expectRevert(abi.encodeWithSelector(MLDSAAttestationV2.UnknownSigner.selector, NEW_PK));
        att.rotateAdd(THIRD_PK, pv, PROOF);
    }

    // ------------------------------------------------------------- revocation

    function test_rotateRevoke_removesKey() public {
        att.rotateAdd(NEW_PK, _stmt(ADD, NEW_PK, GENESIS), PROOF);
        att.rotateRevoke(GENESIS, _stmt(REVOKE, GENESIS, NEW_PK), PROOF);

        assertFalse(att.isAgentPk(GENESIS));
        assertEq(att.agentPkCount(), 1);
        vm.expectRevert(abi.encodeWithSelector(MLDSAAttestationV2.UnknownSigner.selector, GENESIS));
        att.attest(_pv(keccak256("o"), GENESIS), PROOF);
    }

    /// Revocation is retroactive. This is the property that makes "revoked"
    /// mean something for a COMPROMISED key: everything it minted dies with it.
    function test_rotateRevoke_invalidatesPastAttestations() public {
        bytes32 orderHash = keccak256("signed-by-the-compromised-key");
        att.attest(_pv(orderHash, GENESIS), PROOF);
        assertTrue(att.pqAttested(orderHash));

        att.rotateAdd(NEW_PK, _stmt(ADD, NEW_PK, GENESIS), PROOF);
        att.rotateRevoke(GENESIS, _stmt(REVOKE, GENESIS, NEW_PK), PROOF);

        assertFalse(att.pqAttested(orderHash));
        // The forensic record survives even though the authority does not.
        assertEq(att.attestedBy(orderHash), GENESIS);
    }

    /// Documented footgun, pinned so it cannot change silently: authority
    /// resolves THROUGH the key, so re-adding a revoked key resurrects every
    /// attestation it minted. Correct for a key revoked by mistake; never do it
    /// to a key revoked because it was compromised.
    function test_reAddingARevokedKeyResurrectsItsAttestations() public {
        bytes32 orderHash = keccak256("order");
        att.attest(_pv(orderHash, GENESIS), PROOF);

        att.rotateAdd(NEW_PK, _stmt(ADD, NEW_PK, GENESIS), PROOF);
        att.rotateRevoke(GENESIS, _stmt(REVOKE, GENESIS, NEW_PK), PROOF);
        assertFalse(att.pqAttested(orderHash));

        att.rotateAdd(GENESIS, _stmt(ADD, GENESIS, NEW_PK), PROOF);
        assertTrue(att.pqAttested(orderHash));
    }

    /// The no-brick invariant: no reachable sequence empties the authorised set.
    function test_rotateRevoke_cannotEmptyTheSet() public {
        bytes memory pv = _stmt(REVOKE, GENESIS, GENESIS);
        vm.expectRevert(MLDSAAttestationV2.WouldBrick.selector);
        att.rotateRevoke(GENESIS, pv, PROOF);
        assertEq(att.agentPkCount(), 1);
    }

    function test_rotateRevoke_rejectsUnauthorisedSubject() public {
        att.rotateAdd(NEW_PK, _stmt(ADD, NEW_PK, GENESIS), PROOF);
        bytes memory pv = _stmt(REVOKE, THIRD_PK, GENESIS);
        vm.expectRevert(abi.encodeWithSelector(MLDSAAttestationV2.NotAuthorised.selector, THIRD_PK));
        att.rotateRevoke(THIRD_PK, pv, PROOF);
    }

    // ---------------------------------------------------------- guardian path

    function test_recovery_addsKeyAfterDelay() public {
        vm.prank(GUARDIAN);
        att.proposeRecovery(NEW_PK);
        assertEq(att.pendingPkHash(), NEW_PK);

        vm.warp(block.timestamp + DELAY);
        att.executeRecovery();

        assertTrue(att.isAgentPk(NEW_PK));
        assertEq(att.agentPkCount(), 2);
        assertEq(att.pendingPkHash(), bytes32(0));
    }

    function test_recovery_notBeforeEta() public {
        vm.prank(GUARDIAN);
        att.proposeRecovery(NEW_PK);
        vm.warp(block.timestamp + DELAY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(MLDSAAttestationV2.RecoveryNotReady.selector, att.pendingEta())
        );
        att.executeRecovery();
    }

    /// Permissionless on purpose — see the NatSpec on `executeRecovery`.
    function test_recovery_executableByAnyone() public {
        vm.prank(GUARDIAN);
        att.proposeRecovery(NEW_PK);
        vm.warp(block.timestamp + DELAY);
        vm.prank(address(0xBEEF));
        att.executeRecovery();
        assertTrue(att.isAgentPk(NEW_PK));
    }

    function test_recovery_onlyGuardianProposes() public {
        vm.expectRevert(MLDSAAttestationV2.NotGuardian.selector);
        att.proposeRecovery(NEW_PK);
    }

    /// The check on the guardian: a live agent refuses a recovery it did not
    /// ask for, so a compromised guardian gains nothing against a live agent.
    function test_recovery_agentCanVeto() public {
        vm.prank(GUARDIAN);
        att.proposeRecovery(NEW_PK);

        att.vetoRecovery(_stmt(VETO, NEW_PK, GENESIS), PROOF);

        assertEq(att.pendingPkHash(), bytes32(0));
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(MLDSAAttestationV2.NoPendingRecovery.selector);
        att.executeRecovery();
        assertFalse(att.isAgentPk(NEW_PK));
    }

    function test_veto_requiresAuthorisedSigner() public {
        vm.prank(GUARDIAN);
        att.proposeRecovery(NEW_PK);
        // The key being installed cannot veto its own opposition into place.
        bytes memory pv = _stmt(VETO, NEW_PK, NEW_PK);
        vm.expectRevert(abi.encodeWithSelector(MLDSAAttestationV2.UnknownSigner.selector, NEW_PK));
        att.vetoRecovery(pv, PROOF);
    }

    function test_veto_requiresPendingProposal() public {
        bytes memory pv = _stmt(VETO, NEW_PK, GENESIS);
        vm.expectRevert(MLDSAAttestationV2.NoPendingRecovery.selector);
        att.vetoRecovery(pv, PROOF);
    }

    function test_reproposeRestartsTheVetoWindow() public {
        vm.prank(GUARDIAN);
        att.proposeRecovery(NEW_PK);
        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(GUARDIAN);
        att.proposeRecovery(THIRD_PK);
        assertEq(att.pendingPkHash(), THIRD_PK);
        vm.expectRevert();
        att.executeRecovery();
    }

    function test_guardianCanCancelOwnProposal() public {
        vm.prank(GUARDIAN);
        att.proposeRecovery(NEW_PK);
        vm.prank(GUARDIAN);
        att.cancelRecovery();
        assertEq(att.pendingPkHash(), bytes32(0));
    }

    /// The guardian's power is bounded to ADD-after-delay. It has no path to
    /// revoke a key, and no path to attest an order.
    function test_guardianCannotRevokeOrAttest() public {
        vm.prank(GUARDIAN);
        att.proposeRecovery(NEW_PK);
        vm.warp(block.timestamp + DELAY);
        att.executeRecovery();

        // Still cannot remove the agent's own key: revocation is PQ-only, and
        // the guardian cannot produce a proof for an authorised key.
        bytes memory pv = _pv(att.statementHash(REVOKE, GENESIS, att.rotationNonce()), bytes32(0));
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(MLDSAAttestationV2.UnknownSigner.selector, bytes32(0)));
        att.rotateRevoke(GENESIS, pv, PROOF);

        assertTrue(att.isAgentPk(GENESIS));
    }

    // ------------------------------------------------------- guardian handover

    function test_setGuardian_transfersAndDropsPendingProposal() public {
        vm.prank(GUARDIAN);
        att.proposeRecovery(NEW_PK);
        vm.prank(GUARDIAN);
        att.setGuardian(address(0xCAFE));

        assertEq(att.guardian(), address(0xCAFE));
        // A departing guardian must not leave a live proposal behind.
        assertEq(att.pendingPkHash(), bytes32(0));
    }

    function test_setGuardian_renounceIsFinalForTheGuardian() public {
        vm.prank(GUARDIAN);
        att.setGuardian(address(0));
        assertEq(att.guardian(), address(0));

        vm.prank(GUARDIAN);
        vm.expectRevert(MLDSAAttestationV2.NotGuardian.selector);
        att.proposeRecovery(NEW_PK);

        // No guardian remains to appoint a successor.
        vm.prank(address(0));
        vm.expectRevert(MLDSAAttestationV2.RecoverySealed.selector);
        att.setGuardian(GUARDIAN);
    }

    // ------------------------------------- agent authority over the guardian

    /// Vetoing costs the agent a Groth16 proof; proposing costs the guardian
    /// almost nothing. Without this the agent could be drained by a guardian
    /// that re-proposes after every veto, with no way out.
    function test_agentCanFireTheGuardianAndKillItsProposal() public {
        vm.prank(GUARDIAN);
        att.proposeRecovery(NEW_PK);

        att.rotateSetGuardian(
            address(0xDEAD),
            _stmt(4, bytes32(uint256(uint160(address(0xDEAD)))), GENESIS),
            PROOF
        );

        assertEq(att.guardian(), address(0xDEAD));
        // Firing a hostile guardian and killing its live proposal is ONE tx.
        assertEq(att.pendingPkHash(), bytes32(0));

        vm.prank(GUARDIAN);
        vm.expectRevert(MLDSAAttestationV2.NotGuardian.selector);
        att.proposeRecovery(NEW_PK);
    }

    /// The agent may also appoint a guardian after one has renounced — an
    /// outgoing guardian cannot strip a live agent of its recovery option.
    function test_agentCanAppointAfterRenounce() public {
        vm.prank(GUARDIAN);
        att.setGuardian(address(0));

        att.rotateSetGuardian(
            address(0xFEED),
            _stmt(4, bytes32(uint256(uint160(address(0xFEED)))), GENESIS),
            PROOF
        );
        assertEq(att.guardian(), address(0xFEED));

        vm.prank(address(0xFEED));
        att.proposeRecovery(NEW_PK);
        assertEq(att.pendingPkHash(), NEW_PK);
    }

    function test_rotateSetGuardian_requiresAuthorisedSigner() public {
        bytes memory pv = _stmt(4, bytes32(uint256(uint160(address(0xDEAD)))), NEW_PK);
        vm.expectRevert(abi.encodeWithSelector(MLDSAAttestationV2.UnknownSigner.selector, NEW_PK));
        att.rotateSetGuardian(address(0xDEAD), pv, PROOF);
    }

    /// A statement authorising one guardian must not install another.
    function test_rotateSetGuardian_rejectsAddressSubstitution() public {
        bytes memory pv = _stmt(4, bytes32(uint256(uint160(address(0xDEAD)))), GENESIS);
        vm.expectRevert();
        att.rotateSetGuardian(address(0xBEEF), pv, PROOF);
    }

    // -------------------------------------------------- domain separation

    /// A reconfiguration statement must never be producible by signing an
    /// ORDER, and vice versa. Canonical orders are compact JSON — first byte
    /// `{` (0x7b) — and statements always begin with the domain tag's `M`.
    function test_statementCannotCollideWithAnOrder() public view {
        bytes memory s = att.statementBytes(ADD, NEW_PK, 0);
        assertEq(uint8(s[0]), uint8(bytes1("M")));
        assertTrue(uint8(s[0]) != uint8(bytes1("{")));
        assertEq(s.length, 137); // 20 domain + 1 action + 32 chainid + 20 addr + 32 nonce + 32 subject
    }

    /// Conversely, recording an attestation for a statement hash grants no
    /// reconfiguration power — `attest` writes `attestedBy`, nothing else.
    function test_attestingAStatementHashDoesNotRotate() public {
        bytes32 h = att.statementHash(ADD, NEW_PK, 0);
        att.attest(_pv(h, GENESIS), PROOF);
        assertFalse(att.isAgentPk(NEW_PK));
        assertEq(att.agentPkCount(), 1);
        assertEq(att.rotationNonce(), 0);
    }

    /// Statements are bound to THIS contract, so two deployments sharing a key
    /// do not share reconfiguration authority.
    function test_statementIsBoundToThisContract() public {
        MLDSAAttestationV2 other =
            new MLDSAAttestationV2(address(verifier), VKEY, GENESIS, GUARDIAN, DELAY);
        assertTrue(att.statementHash(ADD, NEW_PK, 0) != other.statementHash(ADD, NEW_PK, 0));
    }
}
