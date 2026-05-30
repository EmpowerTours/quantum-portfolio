// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MiniAMM } from "./dex/MiniAMM.sol";
import { WMON }    from "./dex/WMON.sol";

/// @title  RoutingVault — agent-driven on-chain swap executor
/// @notice Upgrade over MonadAllocationVault that actually EXECUTES the
///         agent's recommended allocation by swapping native MON into
///         test ERC20 tokens via MiniAMM pairs. Caller sends MON with
///         the `executeAndRoute` call; vault wraps to WMON, swaps each
///         weighted portion through the requested pair, sends output
///         tokens to msg.sender, and emits the Allocated event so the
///         off-chain audit chain links to a real on-chain trade.
/// @dev    Companion to AuditAnchor.sol. Same provenance flow:
///           1. Agent signs RebalanceOrder off-chain (PQ hedged signature).
///           2. Agent anchors SHA-256 on AuditAnchor.
///           3. User signs `routingVault.executeAndRoute{value: x}(...)`.
///           4. Vault performs real swaps; emits Allocated event with
///              swap output amounts; user receives tokens directly.
contract RoutingVault {
    using SafeERC20 for IERC20;

    WMON public immutable WRAPPED_MON;

    event Allocated(
        address indexed user,
        bytes32 indexed orderHash,
        uint256 amountInWei,
        address[] tokenOuts,
        uint256[] amountsOut,
        uint16[]  weightsBps
    );

    error ZeroValue();
    error ZeroHash();
    error LengthMismatch(uint256 a, uint256 b, uint256 c);
    error WeightsDoNotSumTo10000(uint256 sum);
    error SlippageTooHigh(uint256 idx, uint256 got, uint256 minOut);
    error InvalidPair(uint256 idx);

    constructor(address payable _wmon) {
        WRAPPED_MON = WMON(_wmon);
    }

    /// @notice Execute the agent's allocation by swapping native MON
    ///         into each `tokenOuts[i]` according to `weightsBps[i]`,
    ///         via the pair at `pairs[i]`.
    /// @param  orderHash   SHA-256 of the canonical PQ-signed RebalanceOrder
    /// @param  tokenOuts   each pool's output ERC20 (real address, not label)
    /// @param  pairs       the MiniAMM pair to route through for each token
    /// @param  weightsBps  basis-points weight per pool (sum = 10_000)
    /// @param  minOuts     slippage protection: minimum tokens out per swap
    function executeAndRoute(
        bytes32 orderHash,
        address[] calldata tokenOuts,
        address[] calldata pairs,
        uint16[]  calldata weightsBps,
        uint256[] calldata minOuts
    ) external payable {
        if (msg.value == 0) revert ZeroValue();
        if (orderHash == bytes32(0)) revert ZeroHash();
        uint256 n = tokenOuts.length;
        if (n == 0 || n != pairs.length || n != weightsBps.length || n != minOuts.length) {
            revert LengthMismatch(n, pairs.length, weightsBps.length);
        }
        uint256 sum;
        for (uint256 i = 0; i < n; ++i) sum += weightsBps[i];
        if (sum != 10_000) revert WeightsDoNotSumTo10000(sum);

        // 1. Wrap entire MON deposit into WMON (vault holds it temporarily).
        WRAPPED_MON.deposit{value: msg.value}();

        // 2. For each pool: send weight*WMON to pair, swap, collect output.
        uint256[] memory amountsOut = new uint256[](n);
        uint256 remaining = msg.value;
        for (uint256 i = 0; i < n; ++i) {
            // Use remaining for the final allocation to avoid leftover dust.
            uint256 amountIn = i == n - 1
                ? remaining
                : (msg.value * weightsBps[i]) / 10_000;
            remaining -= amountIn;

            MiniAMM pair = MiniAMM(pairs[i]);
            IERC20 t0 = pair.token0();
            IERC20 t1 = pair.token1();
            bool wmonIsToken0 = address(WRAPPED_MON) == address(t0);
            if (!wmonIsToken0 && address(WRAPPED_MON) != address(t1)) {
                revert InvalidPair(i);
            }
            IERC20 tokenOutInPair = wmonIsToken0 ? t1 : t0;
            if (address(tokenOutInPair) != tokenOuts[i]) revert InvalidPair(i);

            // Get expected output (quotes via the pair's view helper).
            uint256 expectedOut = wmonIsToken0
                ? pair.quoteToken1Out(amountIn)
                : pair.quoteToken0Out(amountIn);
            if (expectedOut < minOuts[i]) {
                revert SlippageTooHigh(i, expectedOut, minOuts[i]);
            }

            // Push WMON to the pair, then call swap to pull tokenOut to msg.sender.
            IERC20(address(WRAPPED_MON)).safeTransfer(address(pair), amountIn);
            if (wmonIsToken0) {
                pair.swap(0, expectedOut, msg.sender);
            } else {
                pair.swap(expectedOut, 0, msg.sender);
            }
            amountsOut[i] = expectedOut;
        }

        emit Allocated(msg.sender, orderHash, msg.value, tokenOuts, amountsOut, weightsBps);
    }

    /// @notice Reject naked sends — every MON inflow must come with an
    ///         orderHash via executeAndRoute. Same invariant as
    ///         MonadAllocationVault.
    receive() external payable {
        revert ZeroHash();
    }
}
