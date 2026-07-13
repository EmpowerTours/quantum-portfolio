// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  IV3SwapRouter — minimal interface to Uniswap's SwapRouter02
/// @notice Only the single-hop exact-input entrypoint we use. The struct
///         and selector match the uniswap swap-router-contracts
///         IV3SwapRouter byte-for-byte (verified against the published
///         SwapRouter02 deployed on Monad mainnet at
///         0xfe31f71c1b106eac32f1a19239c9a9a72ddfb900).
/// @dev    SwapRouter02 removed the per-call `deadline` field that the
///         original V1 SwapRouter carried; deadline enforcement is the
///         caller's responsibility (UniswapRoutingVault adds its own).
interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of
    ///         another, reverting if the received amount is below
    ///         `amountOutMinimum`.
    /// @return amountOut the amount of tokenOut actually received.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
