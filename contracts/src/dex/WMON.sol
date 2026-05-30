// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title  WMON — Wrapped MON (testnet mini-DEX wrapping for native MON)
/// @notice Standard WETH9-style wrap: `deposit()` mints WMON 1:1 against
///         `msg.value` native MON; `withdraw(amount)` burns WMON and
///         sends back native MON. Used by the AllocationRoutingVault as
///         the "WETH" leg of every MON→token swap path.
/// @dev    Minimal ERC20 inheriting OpenZeppelin's audited base. No
///         owner, no fees, no permit (kept out of scope for the
///         submission demo).
contract WMON is ERC20 {
    event Deposit(address indexed dst, uint256 amount);
    event Withdrawal(address indexed src, uint256 amount);

    error InsufficientBalance();
    error TransferFailed();

    constructor() ERC20("Wrapped MON (Testnet)", "WMON") {}

    receive() external payable {
        _depositFor(msg.sender, msg.value);
    }

    function deposit() external payable {
        _depositFor(msg.sender, msg.value);
    }

    function _depositFor(address to, uint256 amount) internal {
        _mint(to, amount);
        emit Deposit(to, amount);
    }

    function withdraw(uint256 amount) external {
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        _burn(msg.sender, amount);
        emit Withdrawal(msg.sender, amount);
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
