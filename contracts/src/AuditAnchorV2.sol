// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  AuditAnchorV2 — provenance anchor that binds an order to the
///         execution it authorises.
///
/// @notice Successor to AuditAnchor (`0x4cB79cc36b367A6fd7363BC6a8553a7A270DA27c`,
///         still live and still the home of the historical proof trail). V1
///         recorded only `lastHash[anchorer]`, which turned out to authorise
///         nothing: the executing contracts checked that *some* hash had been
///         anchored, never that the trade they were about to perform was the
///         trade the signed order described. One anchor could therefore
///         authorise unlimited divergent executions across both the vault and
///         the Morpho adapter. (Audit M-6.)
///
///         V2 fixes that with two changes:
///
///           1. **Execution binding.** Each anchor carries an
///              `execCommitment` — a keccak256 over the exact parameters the
///              executing contract will be called with. The executor
///              recomputes it from its own calldata and refuses to proceed on
///              a mismatch, so on-chain execution provably equals anchored
///              intent. The commitment is derived from fields inside the
///              PQ-signed order, so the ML-DSA signature covers it.
///
///           2. **Membership, not recency.** V1's single `lastHash` slot meant
///              anchoring order N+1 stranded any in-flight execution of order
///              N — a pipelining agent silently dropped trades. (Audit L-1.)
///              V2 keys commitments per `(anchorer, orderHash)`, so anchors
///              stay valid until used and can be pipelined freely.
///
/// @dev    Consumption (single-use enforcement) deliberately lives in the
///         executing contract, not here. Letting executors write to this
///         contract would require an authorised-executor set and make the
///         anchor upgradeable-by-proxy in spirit; keeping it append-only
///         preserves the property that an anchor, once written, is permanent
///         evidence. Each executor tracks its own `(user, orderHash)` usage.
///
///         The `anchor(bytes32)` convenience overload from V1 is intentionally
///         NOT carried over — it skipped sequence race-protection. (Audit L-4.)
contract AuditAnchorV2 {
    /// @notice Emitted once per anchored order.
    /// @param  anchorer       msg.sender — the agent's ECDSA wallet
    /// @param  orderHash      SHA-256 of the canonical signed-order bytes
    /// @param  sequence       monotonically increasing per-anchorer counter
    /// @param  prevHash       previous orderHash anchored by the same address,
    ///                        or bytes32(0) for the first entry
    /// @param  execCommitment keccak256 over the execution parameters this
    ///                        order authorises
    event Anchored(
        address indexed anchorer,
        bytes32 indexed orderHash,
        uint64  indexed sequence,
        bytes32 prevHash,
        bytes32 execCommitment
    );

    /// @notice (anchorer, orderHash) => execution commitment.
    ///         bytes32(0) means "never anchored by this address".
    mapping(address => mapping(bytes32 => bytes32)) public execCommitmentOf;

    /// @notice Per-anchorer monotonic counter. The caller asserts the expected
    ///         value; a mismatch reverts, so a stale or duplicated relay
    ///         cannot land.
    mapping(address => uint64) public nextSequence;

    /// @notice Last orderHash anchored by each address — the on-chain leg of
    ///         the hash chain. Retained for audit-trail continuity only; it is
    ///         NOT an authorisation source. Executors read `execCommitmentOf`.
    mapping(address => bytes32) public lastHash;

    error SequenceMismatch(uint64 expected, uint64 got);
    error ZeroHash();
    error ZeroCommitment();
    error AlreadyAnchored(bytes32 orderHash);

    /// @notice Anchor an order together with the execution it authorises.
    /// @param  orderHash        SHA-256 of `pq_signing.canonical_bytes(order)`
    /// @param  execCommitment   keccak256 over the executor's call parameters,
    ///                          derived from fields inside the signed order
    /// @param  expectedSequence caller's belief about `nextSequence`; reverts
    ///                          on disagreement
    /// @return sequence         the sequence number actually assigned
    function anchor(bytes32 orderHash, bytes32 execCommitment, uint64 expectedSequence)
        external
        returns (uint64 sequence)
    {
        if (orderHash == bytes32(0)) revert ZeroHash();
        if (execCommitment == bytes32(0)) revert ZeroCommitment();

        // An anchor is permanent evidence: never let a commitment be replaced,
        // which would let a caller redirect an already-published order.
        if (execCommitmentOf[msg.sender][orderHash] != bytes32(0)) {
            revert AlreadyAnchored(orderHash);
        }

        sequence = nextSequence[msg.sender];
        if (sequence != expectedSequence) {
            revert SequenceMismatch({ expected: sequence, got: expectedSequence });
        }

        bytes32 prev = lastHash[msg.sender];
        execCommitmentOf[msg.sender][orderHash] = execCommitment;
        lastHash[msg.sender] = orderHash;
        unchecked { nextSequence[msg.sender] = sequence + 1; }

        emit Anchored(msg.sender, orderHash, sequence, prev, execCommitment);
    }
}
