// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  PQBind — build a valid order preimage for tests
/// @notice Since the executors bind execution to the PQ-signed order, a test
///         can no longer invent an `orderHash` out of thin air: it must supply
///         bytes that (a) hash to that orderHash and (b) carry the matching
///         `exec_commitment`. That is the whole point of the fix, so the tests
///         have to do the same work a real signer does.
///
/// @dev    The bytes here are a MINIMAL stand-in, not a full canonical order —
///         `PQExecBinding` only requires the marker to appear exactly once,
///         followed by 64 hex characters and a closing quote. Parity with the
///         real Python canonicaliser is asserted separately, against genuine
///         828-byte output, in test/PQBindParity.t.sol. Keeping the fixture
///         small here keeps 100+ call sites readable.
library PQBind {
    bytes16 private constant HEX = "0123456789abcdef";

    /// @return pre       bytes carrying `commitment` in the expected form
    /// @return orderHash sha256(pre) — the hash the test must anchor and attest
    function preimage(bytes32 commitment)
        internal
        pure
        returns (bytes memory pre, bytes32 orderHash)
    {
        bytes memory hexed = new bytes(64);
        for (uint256 i = 0; i < 32; ++i) {
            hexed[i * 2]     = HEX[uint8(commitment[i]) >> 4];
            hexed[i * 2 + 1] = HEX[uint8(commitment[i]) & 0x0f];
        }
        pre = abi.encodePacked(
            '{"agent_id":"test","execution":{"exec_commitment":"0x', hexed, '"}}'
        );
        orderHash = sha256(pre);
    }
}
