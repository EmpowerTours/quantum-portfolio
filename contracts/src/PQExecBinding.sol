// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  PQExecBinding
/// @notice Proves on-chain that the execution about to run is the execution the
///         post-quantum signature authorised.
///
/// @dev    WHY THIS EXISTS. The ZK attestation commits only
///         `(orderHash, pkHash)`, so it establishes "the pinned ML-DSA key
///         signed *some* order hashing to X" and nothing about what X
///         authorises. The execution binding lived in
///         `AuditAnchorV2.execCommitmentOf`, whose value is chosen by whoever
///         calls `anchor()` — and `AlreadyAnchored` is keyed per-caller, so any
///         address, INCLUDING the agent's own ECDSA key, could bind an
///         arbitrary execution to an already-attested orderHash and execute it.
///         The resulting on-chain record passed every check while describing a
///         trade the signature never authorised. Demonstrated by
///         `test/redteam/RT12_ExecCommitmentUnbound.t.sol`.
///
///         THE FIX. Schema-v3 orders carry `exec_commitment` — a keccak256 over
///         the execution parameters — inside the signed bytes. The executor is
///         handed the order preimage and:
///           1. checks `sha256(preimage) == orderHash`, so the preimage really
///              is the order the attestation covers;
///           2. reads `exec_commitment` out of it;
///           3. recomputes the same hash from its own calldata and compares.
///         A compromised ECDSA key cannot alter step 2's value without breaking
///         step 1, which is the threat model this system declares.
///
///         The order hash is deliberately NOT part of `exec_commitment`.
///         `orderHash = sha256(canonical bytes)` and those bytes now contain
///         the commitment, so including the hash would make the two mutually
///         recursive. Step 1 establishes the order binding directly instead.
library PQExecBinding {
    error PreimageHashMismatch(bytes32 expected, bytes32 got);
    error ExecCommitmentMissing();
    error ExecCommitmentAmbiguous();
    error ExecCommitmentMalformed();
    error ExecCommitmentMismatch(bytes32 signed, bytes32 recomputed);

    /// The canonical JSON is compact (`","`/`":"` separators) with keys sorted,
    /// so the field always appears exactly in this form.
    bytes internal constant MARKER = '"exec_commitment":"0x';

    /// @notice Verify the preimage hashes to `orderHash` and return the
    ///         `exec_commitment` the signer embedded in it.
    function signedCommitment(bytes calldata preimage, bytes32 orderHash)
        internal
        pure
        returns (bytes32 signed)
    {
        bytes32 got = sha256(preimage);
        if (got != orderHash) revert PreimageHashMismatch(orderHash, got);

        // Locate the marker. Require EXACTLY ONE occurrence: a second one — in
        // a pool label, say — would make "the signed commitment" ambiguous, and
        // silently taking the first is how parsers become attack surface.
        uint256 at = type(uint256).max;
        uint256 n = preimage.length;
        uint256 m = MARKER.length;
        if (n < m + 64) revert ExecCommitmentMissing();
        for (uint256 i = 0; i <= n - m; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < m; ++j) {
                if (preimage[i + j] != MARKER[j]) { hit = false; break; }
            }
            if (hit) {
                if (at != type(uint256).max) revert ExecCommitmentAmbiguous();
                at = i;
            }
        }
        if (at == type(uint256).max) revert ExecCommitmentMissing();

        uint256 start = at + m;
        if (start + 64 > n) revert ExecCommitmentMalformed();
        // The 64 hex chars must be followed by the closing quote, otherwise the
        // field is longer than 32 bytes and this is not the value it claims.
        if (preimage[start + 64] != '"') revert ExecCommitmentMalformed();

        uint256 acc;
        for (uint256 k = 0; k < 64; ++k) {
            acc = (acc << 4) | _hexNibble(uint8(preimage[start + k]));
        }
        signed = bytes32(acc);
    }

    /// @dev Rejects anything that is not a lowercase-or-uppercase hex digit.
    ///      Python emits lowercase; accepting both costs nothing and avoids a
    ///      liveness cliff if that ever changes.
    function _hexNibble(uint8 c) private pure returns (uint256) {
        if (c >= 0x30 && c <= 0x39) return c - 0x30;        // 0-9
        if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;   // a-f
        if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;   // A-F
        revert ExecCommitmentMalformed();
    }

    /// @notice keccak256 over the route parameters, WITHOUT the order hash.
    ///         Mirrors `src/monad_tx.route_params_hash` byte for byte.
    function routeParamsHash(
        uint256 chainId,
        address vault,
        address user,
        address[] calldata tokenOuts,
        uint24[] calldata feeTiers,
        uint16[] calldata weightsBps,
        uint256 amountInWei,
        uint256[] calldata amountOutMin,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(chainId, vault, user, tokenOuts, feeTiers,
                       weightsBps, amountInWei, amountOutMin, deadline)
        );
    }

    /// @notice keccak256 over the supply parameters, WITHOUT the order hash.
    ///         Mirrors `src/monad_tx.supply_params_hash`.
    function supplyParamsHash(
        uint256 chainId,
        address adapter,
        address user,
        address loanToken,
        address collateralToken,
        address oracle,
        address irm,
        uint256 lltv,
        uint256 maxAssets
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(chainId, adapter, user, loanToken, collateralToken,
                       oracle, irm, lltv, maxAssets)
        );
    }

    /// @notice Full check: the preimage is the attested order AND it authorises
    ///         exactly these parameters.
    function requireBound(
        bytes calldata preimage,
        bytes32 orderHash,
        bytes32 recomputed
    ) internal pure {
        bytes32 signed = signedCommitment(preimage, orderHash);
        if (signed != recomputed) revert ExecCommitmentMismatch(signed, recomputed);
    }
}
