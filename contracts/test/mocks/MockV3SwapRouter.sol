// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 }        from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }     from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IV3SwapRouter } from "../../src/interfaces/IV3SwapRouter.sol";

/// @notice Deterministic stand-in for Uniswap's SwapRouter02 used by the
///         UniswapRoutingVault unit tests. Pulls `amountIn` of tokenIn from
///         the caller (the vault, which has approved it) and pays out
///         `amountIn * rateNum / rateDen` of tokenOut to `recipient` from
///         its own pre-funded inventory, honouring `amountOutMinimum`
///         exactly the way the real router does (revert if unmet).
contract MockV3SwapRouter is IV3SwapRouter {
    using SafeERC20 for IERC20;

    /// @notice Output-per-input rate, applied as amountIn * num / den.
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;

    error TooLittleReceived(uint256 got, uint256 min);

    function setRate(uint256 num, uint256 den) external {
        rateNum = num;
        rateDen = den;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        amountOut = (p.amountIn * rateNum) / rateDen;
        if (amountOut < p.amountOutMinimum) {
            revert TooLittleReceived(amountOut, p.amountOutMinimum);
        }
        IERC20(p.tokenOut).safeTransfer(p.recipient, amountOut);
    }
}
