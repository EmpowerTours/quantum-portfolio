// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISP1Verifier} from "@sp1-contracts/ISP1Verifier.sol";

/// @notice Public values committed by the SP1 ML-DSA guest. Unchanged from v1:
///         this contract deliberately reuses the SAME guest program and the
///         SAME vkey, so adopting it costs nothing on the proving side.
struct PublicValuesStruct {
    bytes32 orderHash;
    bytes32 pkHash;
}

/// @title  MLDSAAttestationV2
/// @notice MLDSAAttestation plus a rotation path for the agent key.
///
/// @dev    WHY THIS EXISTS.
///         v1 (`0xb0aADaFe68647578520E988b4444e556c300b4Da`) pins exactly one
///         `agentPkHash`, `immutable`, no setter. The executors pin `PQ()`
///         `immutable` in turn. So rotating or replacing the ML-DSA identity
///         means redeploying this contract AND every executor that points at
///         it — which is the same "authentication cannot be upgraded without
///         abandoning the address" failure the Monad
///         flexible-account-authentication MIP is written against.
///
///         It is not hypothetical here either: the 2026-07-12 signing identity
///         `8a1b08d1…` was lost outright. Under v1 that class of event is
///         unrecoverable by construction.
///
///         WHAT CHANGED. One pinned key becomes a SET of authorised keys, and
///         the set is reconfigurable through two paths with deliberately
///         different powers:
///
///           1. PQ path — instant, authorised by a Groth16 proof that a
///              CURRENTLY authorised ML-DSA key signed the reconfiguration
///              statement. May add a key, revoke a key, or veto (2). This is
///              the planned-rotation path: you still hold the old key.
///
///           2. Guardian path — `proposeRecovery` + a fixed delay + a
///              permissionless `executeRecovery`. This is the key-LOSS path,
///              the one a PQ-authorised path cannot serve because the whole
///              premise is that no valid signature can be produced any more.
///
///         The guardian can ONLY ADD a key, and only after the delay has run
///         without a veto. It can never revoke, never attest, and never act
///         instantly. So the worst a fully compromised guardian achieves
///         against a live agent is a public proposal the agent vetoes with one
///         proof; and against a dead agent it achieves exactly the recovery it
///         exists for. That asymmetry is the point — an owner-style setter
///         would put a secp256k1 key in charge of a post-quantum authority and
///         quietly make the ECDSA key the weakest link in a system whose
///         entire claim is that it is not.
///
///         NO-BRICK INVARIANT (mirrors the MIP's "a configuration that cannot
///         be satisfied can never be installed"): `agentPkCount >= 1` holds
///         after every operation. Revocation of the last key reverts.
///
///         REVOCATION IS RETROACTIVE. `pqAttested` resolves through the key
///         that produced the attestation, so revoking a compromised key voids
///         every attestation it ever minted, including already-recorded ones.
///         A revoked key's past approvals are worth exactly nothing, which is
///         the only reading of "revoked" that is worth having. The corollary:
///         do NOT revoke a merely-lost key that has unexecuted orders in
///         flight — add the new key first, let them settle, then revoke.
///
///         The same rule read backwards: re-adding a previously revoked key
///         RESURRECTS every attestation it minted, because authority resolves
///         through the key rather than being copied at attest time. That is
///         the correct behaviour for a key revoked by mistake and a footgun
///         for one revoked because it was compromised. Never re-add a
///         compromised key; deploy a fresh contract if you need its history
///         back.
contract MLDSAAttestationV2 {
    // ---------------------------------------------------------------- config

    /// @notice SP1 verifier (version-specific SP1Verifier or the gateway).
    address public immutable verifier;

    /// @notice Verification key of the ML-DSA-65 guest program. Unchanged from
    ///         v1 — the guest commits `(sha256(msg), sha256(pk))` over an
    ///         arbitrary message, which is precisely what lets a
    ///         reconfiguration statement be authorised by the same proof
    ///         system that authorises orders.
    bytes32 public immutable mldsaProgramVKey;

    /// @notice The key the contract was deployed with. Kept for the audit
    ///         trail ONLY — it is not the live policy and may have been
    ///         revoked. Read `isAgentPk` for authority.
    bytes32 public immutable genesisAgentPkHash;

    /// @notice Delay between `proposeRecovery` and `executeRecovery`.
    uint64 public immutable recoveryDelay;

    // ----------------------------------------------------------------- state

    /// @notice The live signing policy: any ONE key in this set may attest.
    mapping(bytes32 => bool) public isAgentPk;

    /// @notice Size of that set. Never zero after construction.
    uint256 public agentPkCount;

    /// @notice Monotonic counter binding each PQ-authorised statement to one
    ///         use. Incremented by every successful `rotate*`/`veto` call.
    uint256 public rotationNonce;

    /// @notice Recovery authority. May only ADD a key, only via the timelock,
    ///         and only if the agent does not veto. `address(0)` = no recovery
    ///         authority right now; an authorised agent key can appoint one at
    ///         any time via `rotateSetGuardian`.
    address public guardian;

    /// @notice Pending recovery proposal (zero when none).
    bytes32 public pendingPkHash;
    uint64  public pendingEta;

    /// @notice orderHash => the agent key whose proof attested it. Zero if
    ///         never attested. `pqAttested` reads authority through this, so
    ///         revocation invalidates retroactively.
    mapping(bytes32 => bytes32) public attestedBy;

    // ---------------------------------------------------------------- events

    event PQOrderAttested(bytes32 indexed orderHash, bytes32 indexed pkHash);
    /// @dev No nonce field: on the PQ path the authorising nonce is
    ///      `rotationNonce - 1` (it is consumed before the event) and on the
    ///      guardian path there is none, so one argument would mean two
    ///      different things. The transaction records the call either way.
    event AgentKeyAdded(bytes32 indexed pkHash, bool viaGuardian);
    event AgentKeyRevoked(bytes32 indexed pkHash);
    event RecoveryProposed(bytes32 indexed pkHash, uint64 eta);
    event RecoveryExecuted(bytes32 indexed pkHash);
    event RecoveryCancelled(bytes32 indexed pkHash, bool byGuardian);
    event GuardianChanged(address indexed previous, address indexed current);

    // ---------------------------------------------------------------- errors

    error UnknownSigner(bytes32 got);
    error NotGuardian();
    error AlreadyAuthorised(bytes32 pkHash);
    error NotAuthorised(bytes32 pkHash);
    error WouldBrick();
    error ZeroKey();
    error NoPendingRecovery();
    error RecoveryNotReady(uint64 eta);
    error StatementMismatch(bytes32 expected, bytes32 got);
    error RecoverySealed();

    // ------------------------------------------------------- auth statements

    /// @dev Domain tag for reconfiguration statements. Canonical orders are
    ///      compact JSON and always begin with `{`, so no order preimage can
    ///      ever collide with a statement preimage — the first byte separates
    ///      them. See `RT_StatementDomainSeparation` in the test suite.
    // casting to 'bytes20' is safe because the literal is exactly 20 bytes
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes20 internal constant DOMAIN = bytes20("MLDSA-ATTEST-V2-AUTH");

    uint8 internal constant ACTION_ADD    = 1;
    uint8 internal constant ACTION_REVOKE = 2;
    uint8 internal constant ACTION_VETO   = 3;
    uint8 internal constant ACTION_SET_GUARDIAN = 4;

    /// @notice The exact bytes the agent must ML-DSA-sign to authorise
    ///         `action` on `subject` at the current nonce.
    ///
    /// @dev    Fixed 137-byte layout, recomputed by the contract from its own
    ///         state and the caller's arguments — there is no parser here and
    ///         no field the caller controls that is not already bound. Mirrored
    ///         byte for byte by `src/pq_rotation.statement_bytes` in Python;
    ///         `MLDSAAttestationV2Parity.t.sol` and `tests/test_pq_rotation.py`
    ///         assert the same goldens on both sides.
    ///
    ///         Bound: the domain tag, the action, `block.chainid`,
    ///         `address(this)` and the nonce. Chain id and address stop a
    ///         statement signed for a testnet deployment from being replayed
    ///         against mainnet; the nonce makes every statement single-use.
    function statementBytes(uint8 action, bytes32 subject, uint256 nonce)
        public
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            DOMAIN, action, uint256(block.chainid), address(this), nonce, subject
        );
    }

    /// @notice `sha256` of `statementBytes` — the value the guest commits as
    ///         `orderHash` when the agent signs that statement.
    function statementHash(uint8 action, bytes32 subject, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        return sha256(statementBytes(action, subject, nonce));
    }

    // ----------------------------------------------------------- constructor

    /// @dev `verifier` and `mldsaProgramVKey` stay immutable for the same
    ///      reason as v1 — a wrong verifier bricks `attest` uncatchably rather
    ///      than silently accepting an unverified proof, and there is no
    ///      recovery story that a setter would improve without also handing
    ///      whoever holds the setter the power to accept forged proofs.
    ///
    ///      `guardian` is REQUIRED at deploy. Shipping without one reproduces
    ///      exactly the v1 failure this contract exists to remove; giving it up
    ///      later is a deliberate act (`setGuardian(address(0))` by the
    ///      guardian, or `rotateSetGuardian(address(0))` by the agent), not a
    ///      default.
    constructor(
        address _verifier,
        bytes32 _mldsaProgramVKey,
        bytes32 _agentPkHash,
        address _guardian,
        uint64  _recoveryDelay
    ) {
        require(_agentPkHash != bytes32(0), "agentPkHash unset");
        require(_mldsaProgramVKey != bytes32(0), "mldsaProgramVKey unset");
        require(_verifier.code.length > 0, "verifier has no code");
        require(_guardian != address(0), "guardian unset");
        // Floor: a delay short enough to outrun a human response is not a
        // veto window. Ceiling: a delay longer than the project's memory is
        // not a recovery path.
        require(_recoveryDelay >= 2 days && _recoveryDelay <= 30 days, "recoveryDelay out of range");

        verifier = _verifier;
        mldsaProgramVKey = _mldsaProgramVKey;
        genesisAgentPkHash = _agentPkHash;
        recoveryDelay = _recoveryDelay;
        guardian = _guardian;

        isAgentPk[_agentPkHash] = true;
        agentPkCount = 1;
        emit AgentKeyAdded(_agentPkHash, false);
        emit GuardianChanged(address(0), _guardian);
    }

    // -------------------------------------------------------------- attesting

    /// @notice Verify the SP1 proof; on success record & emit the attested
    ///         `orderHash`. Reverts if the proof is invalid or if the signing
    ///         key is not currently authorised.
    function attest(bytes calldata _publicValues, bytes calldata _proofBytes)
        external
        returns (bytes32 orderHash)
    {
        PublicValuesStruct memory pv = _verified(_publicValues, _proofBytes);
        orderHash = pv.orderHash;
        attestedBy[orderHash] = pv.pkHash;
        emit PQOrderAttested(orderHash, pv.pkHash);
    }

    /// @notice Has a valid ML-DSA-65 signature over this orderHash been proven
    ///         by a key that is STILL authorised?
    /// @dev    Satisfies `IPQAttestation`. Deliberately not a plain mapping
    ///         getter: revoking a compromised key must void what it signed.
    function pqAttested(bytes32 orderHash) external view returns (bool) {
        bytes32 pk = attestedBy[orderHash];
        return pk != bytes32(0) && isAgentPk[pk];
    }

    /// @notice View-only proof check (records nothing). Applies the same
    ///         authorisation check as `attest` — a view that accepted any
    ///         signer would be a trap for integrators reading it as "is this
    ///         order valid".
    function isValidProof(bytes calldata _publicValues, bytes calldata _proofBytes)
        external
        view
        returns (bytes32 orderHash)
    {
        return _verified(_publicValues, _proofBytes).orderHash;
    }

    // --------------------------------------------------------------- PQ path

    /// @notice Add `newPkHash` to the authorised set, authorised by a proof
    ///         that a currently authorised key signed
    ///         `statementBytes(ACTION_ADD, newPkHash, rotationNonce)`.
    function rotateAdd(bytes32 newPkHash, bytes calldata _publicValues, bytes calldata _proofBytes)
        external
    {
        _requireStatement(ACTION_ADD, newPkHash, _publicValues, _proofBytes);
        _add(newPkHash, false);
    }

    /// @notice Revoke `pkHash`, authorised the same way. Retroactive: every
    ///         attestation minted by `pkHash` stops resolving. Cannot empty
    ///         the set.
    /// @dev    Self-revocation is permitted and is the normal end of a
    ///         rotation (add new key, then have the NEW key revoke the old
    ///         one — do not ask the outgoing key to revoke itself unless you
    ///         are certain nothing else is in flight).
    function rotateRevoke(bytes32 pkHash, bytes calldata _publicValues, bytes calldata _proofBytes)
        external
    {
        _requireStatement(ACTION_REVOKE, pkHash, _publicValues, _proofBytes);
        if (!isAgentPk[pkHash]) revert NotAuthorised(pkHash);
        if (agentPkCount == 1) revert WouldBrick();
        isAgentPk[pkHash] = false;
        unchecked { agentPkCount -= 1; }
        emit AgentKeyRevoked(pkHash);
    }

    /// @notice Cancel the pending guardian recovery. This is the check on the
    ///         guardian: a live agent refuses a recovery it did not ask for.
    function vetoRecovery(bytes calldata _publicValues, bytes calldata _proofBytes) external {
        bytes32 pending = pendingPkHash;
        if (pending == bytes32(0)) revert NoPendingRecovery();
        _requireStatement(ACTION_VETO, pending, _publicValues, _proofBytes);
        _clearPending();
        emit RecoveryCancelled(pending, false);
    }

    /// @notice Replace (or seal, with `address(0)`) the guardian, authorised by
    ///         a currently authorised agent key.
    ///
    /// @dev    WHY THE AGENT MUST BE ABLE TO DO THIS. Vetoing costs a Groth16
    ///         proof; proposing costs the guardian one cheap call. A guardian
    ///         that re-proposes after every veto therefore drains the agent for
    ///         almost nothing, and if only the guardian could call
    ///         `setGuardian` there would be no way out of that loop. The agent
    ///         is the principal here and the guardian is its delegate; a
    ///         principal that cannot fire its delegate is not in charge.
    ///
    ///         This costs recovery nothing: an agent that can produce this
    ///         proof is by definition not the lost-key case the guardian
    ///         exists for.
    ///
    ///         Any pending proposal is dropped, so firing a hostile guardian
    ///         and killing its live proposal is one transaction, not a race.
    function rotateSetGuardian(
        address newGuardian,
        bytes calldata _publicValues,
        bytes calldata _proofBytes
    ) external {
        _requireStatement(
            ACTION_SET_GUARDIAN, bytes32(uint256(uint160(newGuardian))),
            _publicValues, _proofBytes
        );
        address prev = guardian;
        bytes32 pk = pendingPkHash;
        if (pk != bytes32(0)) {
            _clearPending();
            emit RecoveryCancelled(pk, false);
        }
        guardian = newGuardian;
        emit GuardianChanged(prev, newGuardian);
    }

    // --------------------------------------------------------- guardian path

    /// @notice Propose adding `newPkHash` after `recoveryDelay`. Re-proposing
    ///         replaces any pending proposal and restarts the veto window.
    function proposeRecovery(bytes32 newPkHash) external {
        if (msg.sender != guardian) revert NotGuardian();
        if (newPkHash == bytes32(0)) revert ZeroKey();
        if (isAgentPk[newPkHash]) revert AlreadyAuthorised(newPkHash);
        pendingPkHash = newPkHash;
        pendingEta = uint64(block.timestamp) + recoveryDelay;
        emit RecoveryProposed(newPkHash, pendingEta);
    }

    /// @notice Execute a matured, un-vetoed proposal. Permissionless on
    ///         purpose: the proposal has been public for the whole delay, and
    ///         a recovery that also requires the guardian to be online at
    ///         maturity is a recovery with two ways to fail instead of one.
    function executeRecovery() external {
        bytes32 pk = pendingPkHash;
        if (pk == bytes32(0)) revert NoPendingRecovery();
        if (block.timestamp < pendingEta) revert RecoveryNotReady(pendingEta);
        _clearPending();
        _add(pk, true);
        emit RecoveryExecuted(pk);
    }

    /// @notice Guardian withdraws its own proposal.
    function cancelRecovery() external {
        if (msg.sender != guardian) revert NotGuardian();
        bytes32 pk = pendingPkHash;
        if (pk == bytes32(0)) revert NoPendingRecovery();
        _clearPending();
        emit RecoveryCancelled(pk, true);
    }

    /// @notice Hand the guardian role over, or pass `address(0)` to renounce.
    ///
    /// @dev    Renouncing is irreversible FROM THE GUARDIAN SIDE — there is no
    ///         guardian left to appoint a successor — but the agent can always
    ///         appoint one through `rotateSetGuardian`. So a departing guardian
    ///         cannot strip a live agent of its recovery option; it can only
    ///         give up its own. What renouncing DOES reinstate is the v1
    ///         failure mode for a key that is lost while no guardian is set,
    ///         which is a legitimate end state — e.g. once Monad ships
    ///         protocol-level account authentication and this layer no longer
    ///         needs its own recovery.
    ///
    ///         Any pending proposal is dropped, so a departing guardian cannot
    ///         leave a live one behind.
    function setGuardian(address newGuardian) external {
        address prev = guardian;
        if (msg.sender != prev) revert NotGuardian();
        if (prev == address(0)) revert RecoverySealed();
        bytes32 pk = pendingPkHash;
        if (pk != bytes32(0)) {
            _clearPending();
            emit RecoveryCancelled(pk, true);
        }
        guardian = newGuardian;
        emit GuardianChanged(prev, newGuardian);
    }

    // -------------------------------------------------------------- internals

    /// @dev Verify the proof and require the committing key to be authorised.
    ///      Mirrors v1's ordering: the verifier runs FIRST, so a caller cannot
    ///      probe the authorised set with unverified public values.
    function _verified(bytes calldata _publicValues, bytes calldata _proofBytes)
        internal
        view
        returns (PublicValuesStruct memory pv)
    {
        ISP1Verifier(verifier).verifyProof(mldsaProgramVKey, _publicValues, _proofBytes);
        pv = abi.decode(_publicValues, (PublicValuesStruct));
        if (!isAgentPk[pv.pkHash]) revert UnknownSigner(pv.pkHash);
    }

    /// @dev Verify the proof, require an authorised signer, and require that
    ///      what was signed is EXACTLY the statement for this action, subject
    ///      and current nonce. Consumes the nonce on success.
    function _requireStatement(
        uint8 action,
        bytes32 subject,
        bytes calldata _publicValues,
        bytes calldata _proofBytes
    ) internal {
        PublicValuesStruct memory pv = _verified(_publicValues, _proofBytes);
        bytes32 expected = statementHash(action, subject, rotationNonce);
        if (pv.orderHash != expected) revert StatementMismatch(expected, pv.orderHash);
        unchecked { rotationNonce += 1; }
    }

    function _add(bytes32 pkHash, bool viaGuardian) internal {
        if (pkHash == bytes32(0)) revert ZeroKey();
        if (isAgentPk[pkHash]) revert AlreadyAuthorised(pkHash);
        isAgentPk[pkHash] = true;
        unchecked { agentPkCount += 1; }
        emit AgentKeyAdded(pkHash, viaGuardian);
    }

    function _clearPending() internal {
        pendingPkHash = bytes32(0);
        pendingEta = 0;
    }
}
