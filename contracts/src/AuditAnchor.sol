// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  AuditAnchor — minimal on-chain anchor for off-chain PQ-signed orders
/// @notice Bridges the off-chain hash-chained audit log of the Quantum-Safe
///         DeFi Allocation Agents to on-chain immutability. The agent
///         computes the SHA-256 of each canonical, hedge-signed `RebalanceOrder`
///         off-chain and submits that 32-byte digest here. The contract emits
///         an event so any indexer (or a future PQ-aware verifier) can prove
///         the order existed at a given block height without storing
///         the (~33 KB) hedged signatures on-chain.
/// @dev    We deliberately do NOT verify ML-DSA or SLH-DSA on-chain. A
///         pure-Solidity ML-DSA verifier costs ~500 M gas per call (see
///         hackernoon.com/comparing-on-chain-post-quantum-signature-verification-for-ethereum,
///         2026). The signed-order JSON, the three signatures, and the three
///         public keys all stay in the off-chain audit log; this contract
///         only anchors the SHA-256 digest, which is ~30 K gas per call and
///         remains useful even after EVM chains adopt native PQ signatures.
contract AuditAnchor {
    /// @notice Emitted once per anchored order.
    /// @param  anchorer      msg.sender — typically the agent's ECDSA wallet
    /// @param  orderHash     SHA-256 of the canonical signed-order bytes
    /// @param  sequence      monotonically increasing per-anchorer counter
    /// @param  prevHash      previous SHA-256 anchored by the same address,
    ///                       or bytes32(0) for the first entry. Mirrors the
    ///                       off-chain hash-chain — a missing on-chain entry
    ///                       breaks the chain just like a missing JSONL line
    event Anchored(
        address indexed anchorer,
        bytes32 indexed orderHash,
        uint64 indexed sequence,
        bytes32 prevHash
    );

    /// @notice Per-anchorer monotonic counter. Caller asserts the expected
    ///         sequence number; the call reverts on mismatch. This makes
    ///         a stale or duplicated relay impossible to land — the agent
    ///         can recover the off-chain audit-log index from a chain scan.
    mapping(address => uint64) public nextSequence;

    /// @notice Last hash anchored by each address. Forms the on-chain leg of
    ///         the hash chain. The agent reads this before constructing
    ///         the next anchor call so the on-chain and off-chain chains stay
    ///         linked. bytes32(0) means "no anchors yet from this address".
    mapping(address => bytes32) public lastHash;

    error SequenceMismatch(uint64 expected, uint64 got);
    error ZeroHash();

    /// @notice Anchor a SHA-256 digest of a canonical signed RebalanceOrder.
    /// @param  orderHash       SHA-256 of `pq_signing.canonical_bytes(order)`
    /// @param  expectedSequence what the caller believes nextSequence to be;
    ///         reverts if the contract disagrees. Protects against double-
    ///         submission from a relayer race.
    /// @return sequence         the sequence number actually assigned
    function anchor(bytes32 orderHash, uint64 expectedSequence)
        external
        returns (uint64 sequence)
    {
        if (orderHash == bytes32(0)) revert ZeroHash();

        sequence = nextSequence[msg.sender];
        if (sequence != expectedSequence) {
            revert SequenceMismatch({ expected: sequence, got: expectedSequence });
        }

        bytes32 prev = lastHash[msg.sender];
        lastHash[msg.sender] = orderHash;
        unchecked { nextSequence[msg.sender] = sequence + 1; }

        emit Anchored(msg.sender, orderHash, sequence, prev);
    }

    /// @notice Convenience overload that reads the current `nextSequence`
    ///         server-side. Loses race-protection — use the explicit form
    ///         from production code paths.
    function anchor(bytes32 orderHash) external returns (uint64 sequence) {
        if (orderHash == bytes32(0)) revert ZeroHash();

        sequence = nextSequence[msg.sender];
        bytes32 prev = lastHash[msg.sender];
        lastHash[msg.sender] = orderHash;
        unchecked { nextSequence[msg.sender] = sequence + 1; }

        emit Anchored(msg.sender, orderHash, sequence, prev);
    }
}
