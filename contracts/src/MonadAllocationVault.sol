// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  MonadAllocationVault — minimal Monad-native vault that records
///         agent-recommended MON allocations and lets users withdraw them
/// @notice Companion to AuditAnchor.sol. The full pipeline is:
///           1. agent runs QAOA on a real QPU and produces a PQ-signed
///              RebalanceOrder (off-chain artefact)
///           2. agent anchors SHA-256(canonical(order)) on AuditAnchor
///           3. user signs `vault.execute{value: x MON}(orderHash, pools, weights)`
///              which records the allocation and emits an Allocated event
///         Two on-chain transactions reference the same `orderHash`; an
///         indexer (or a Santander reviewer with `cast call`) reconstructs
///         the end-to-end provenance trail without trusting us.
/// @dev    Uses native MON (msg.value) so we do not ship a test ERC20.
///         The pool list is plain `bytes32[]` — these are agent labels
///         interpreted by the off-chain order, not necessarily on-chain
///         contract addresses. When a Monad DEX ships on testnet and we
///         add real routing, this contract is upgraded by deploying a
///         routing-aware successor; the agent-facing event shape stays
///         stable so historical orders remain replayable against the
///         on-chain log.
contract MonadAllocationVault {
    /// @notice Per-user, per-orderHash MON deposit. Allows withdraw by
    ///         the same user without exposing other users' deposits.
    mapping(address => mapping(bytes32 => uint256)) public deposits;

    /// @notice Per-user lifetime MON deposited (sum over all orderHashes).
    mapping(address => uint256) public totalDeposited;

    /// @notice Per-user lifetime MON withdrawn.
    mapping(address => uint256) public totalWithdrawn;

    /// @notice Emitted on execute. Indexed fields let an off-chain
    ///         indexer reconstruct any user's allocation history with a
    ///         single eth_getLogs call.
    /// @param  user        msg.sender; the wallet that signed and broadcast
    /// @param  orderHash   SHA-256 of the canonical PQ-signed order; must
    ///                     already be anchored on AuditAnchor for the
    ///                     provenance trail to hold (we don't enforce
    ///                     anchor existence on-chain so anyone can verify
    ///                     off-chain, but it's the protocol convention)
    /// @param  amountWei   msg.value
    /// @param  pools       pool identifiers from the off-chain RebalanceOrder
    /// @param  weightsBps  per-pool weights in basis points (sum = 10000)
    event Allocated(
        address indexed user,
        bytes32 indexed orderHash,
        uint256 amountWei,
        bytes32[] pools,
        uint16[]  weightsBps
    );

    /// @notice Emitted on withdraw.
    event Withdrawn(address indexed user, bytes32 indexed orderHash, uint256 amountWei);

    error ZeroValue();
    error ZeroHash();
    error LengthMismatch(uint256 pools, uint256 weights);
    error WeightsDoNotSumTo10000(uint256 sum);
    error InsufficientDeposit(uint256 requested, uint256 available);
    error TransferFailed();

    /// @notice Record an allocation of `msg.value` MON to `pools` under
    ///         the agent's `orderHash`. Funds stay in the vault until
    ///         the same user calls `withdraw` against the same orderHash.
    /// @param  orderHash      SHA-256 of the canonical PQ-signed order
    /// @param  pools          bytes32[] of pool labels (e.g., keccak of
    ///                        "Morpho STEAKETH (Monad)"); kept as bytes32
    ///                        because Monad pool labels are human strings
    ///                        in the off-chain order, not addresses yet
    /// @param  weightsBps     basis-points weight per pool (sum = 10000)
    function execute(
        bytes32 orderHash,
        bytes32[] calldata pools,
        uint16[]  calldata weightsBps
    ) external payable {
        if (msg.value == 0) revert ZeroValue();
        if (orderHash == bytes32(0)) revert ZeroHash();
        if (pools.length != weightsBps.length) {
            revert LengthMismatch(pools.length, weightsBps.length);
        }

        uint256 weightSum;
        for (uint256 i = 0; i < weightsBps.length; ++i) {
            weightSum += weightsBps[i];
        }
        if (weightSum != 10_000) revert WeightsDoNotSumTo10000(weightSum);

        deposits[msg.sender][orderHash] += msg.value;
        totalDeposited[msg.sender]      += msg.value;

        emit Allocated(msg.sender, orderHash, msg.value, pools, weightsBps);
    }

    /// @notice Withdraw `amountWei` of MON previously deposited under
    ///         `orderHash` by msg.sender.
    function withdraw(bytes32 orderHash, uint256 amountWei) external {
        uint256 available = deposits[msg.sender][orderHash];
        if (amountWei > available) revert InsufficientDeposit(amountWei, available);

        // Checks-effects-interactions: zero balance before external call.
        deposits[msg.sender][orderHash] = available - amountWei;
        totalWithdrawn[msg.sender]     += amountWei;

        emit Withdrawn(msg.sender, orderHash, amountWei);

        (bool ok, ) = msg.sender.call{value: amountWei}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Convenience: vault's total MON balance. NOTE: this returns
    ///         `address(this).balance`, which any force-credit vector
    ///         can inflate without going through `execute`. Vectors
    ///         include: (a) `SELFDESTRUCT` with vault as recipient
    ///         (still possible from contracts deployed before Cancun's
    ///         restriction); (b) `block.coinbase` set to the vault
    ///         (a validator-side attack on PoS chains, real on Monad);
    ///         (c) genesis prefunding (irrelevant post-deploy). The
    ///         accurate per-user accounting lives in
    ///         `deposits[user][orderHash]` and is unaffected. Use this
    ///         view only for monitoring, not for protocol invariants.
    ///         A future mainnet redeploy can switch to an explicit
    ///         `internalBalance` counter if external invariants need
    ///         to depend on it.
    function totalLocked() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Reject naked MON transfers. The only path in is `execute`.
    ///         Forces every deposit to carry an orderHash, which is the
    ///         protocol's core invariant.
    receive() external payable {
        revert ZeroHash();
    }
}
