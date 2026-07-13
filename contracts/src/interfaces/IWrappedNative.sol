// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  IWrappedNative — WETH9-style wrapped-native interface
/// @notice The canonical Wrapped MON on Monad mainnet
///         (0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A) exposes the same
///         `deposit()` / `withdraw(uint256)` surface as WETH9 on top of
///         the ERC20 base, which is why this extends IERC20.
interface IWrappedNative is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
