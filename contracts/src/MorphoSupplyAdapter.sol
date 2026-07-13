// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 }          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AuditAnchor }     from "./AuditAnchor.sol";
import { IMorpho, MarketParams } from "./interfaces/IMorpho.sol";

/// @title  MorphoSupplyAdapter — agent-driven yield deposit into Morpho Blue.
/// @notice Companion to UniswapRoutingVault. Where the vault executes the
///         *swap* leg of an agent's PQ-signed allocation (native MON -> a
///         DeFi token), this adapter executes the *yield-deposit* leg:
///         it supplies the loan token into a real Morpho Blue lending market
///         so the user earns lending yield, still gated on the same on-chain
///         provenance anchor.
///
///         Flow per call:
///           1. caller must have most-recently anchored `orderHash` on
///              AuditAnchor (same provenance gate as the vault)
///           2. pull `assets` of the market's loan token from the caller
///           3. supply them to Morpho ON BEHALF OF THE CALLER, so the user
///              directly owns the Morpho supply position (non-custodial —
///              they withdraw straight from Morpho, not from this adapter)
///           4. assert the adapter retains no loan-token dust; emit Supplied
///
/// @dev    The set of loan tokens this adapter may supply is frozen at
///         construction (mirrors the vault's approved-token allowlist), so
///         the trust boundary is immutable — to add a market's loan token,
///         deploy a new adapter.
contract MorphoSupplyAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IMorpho     public immutable MORPHO;
    AuditAnchor public immutable ANCHOR;

    /// @notice Loan tokens this adapter is permitted to supply. Frozen at deploy.
    mapping(address => bool) public isApprovedLoanToken;

    event Supplied(
        address indexed user,
        bytes32 indexed orderHash,
        bytes32 indexed marketId,
        address loanToken,
        uint256 assets,
        uint256 shares
    );

    error ZeroAssets();
    error ZeroHash();
    error AnchorNotFound(bytes32 expected);
    error LoanTokenNotApproved(address token);
    error DustResidual(uint256 amount);

    constructor(address _morpho, address _anchor, address[] memory _approvedLoanTokens) {
        MORPHO = IMorpho(_morpho);
        ANCHOR = AuditAnchor(_anchor);
        for (uint256 i = 0; i < _approvedLoanTokens.length; ++i) {
            isApprovedLoanToken[_approvedLoanTokens[i]] = true;
        }
    }

    /// @notice Supply `assets` of `params.loanToken` into the Morpho market
    ///         `params`, on behalf of the caller.
    /// @param  orderHash SHA-256 of the canonical PQ-signed order; MUST equal
    ///                   AuditAnchor.lastHash[msg.sender] (anchor first, then
    ///                   supply, with no intervening anchor).
    /// @param  params    the Morpho Blue market to supply into.
    /// @param  assets    amount of the loan token to supply (exact assets).
    /// @return shares    supply shares credited to the caller by Morpho.
    function supply(bytes32 orderHash, MarketParams calldata params, uint256 assets)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAssets();
        if (orderHash == bytes32(0)) revert ZeroHash();
        if (ANCHOR.lastHash(msg.sender) != orderHash) revert AnchorNotFound(orderHash);
        if (!isApprovedLoanToken[params.loanToken]) revert LoanTokenNotApproved(params.loanToken);

        IERC20 loan = IERC20(params.loanToken);
        loan.safeTransferFrom(msg.sender, address(this), assets);
        loan.forceApprove(address(MORPHO), assets);

        // onBehalf = msg.sender: the user owns the supply position directly.
        (, shares) = MORPHO.supply(params, assets, 0, msg.sender, "");

        // Reset the allowance and assert no loan-token dust is retained.
        loan.forceApprove(address(MORPHO), 0);
        uint256 dust = loan.balanceOf(address(this));
        if (dust != 0) revert DustResidual(dust);

        emit Supplied(
            msg.sender,
            orderHash,
            keccak256(abi.encode(params)),
            params.loanToken,
            assets,
            shares
        );
    }
}
