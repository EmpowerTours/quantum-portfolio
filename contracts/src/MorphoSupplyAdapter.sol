// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 }          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AuditAnchorV2 }   from "./AuditAnchorV2.sol";
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
///           1. caller must have anchored `orderHash` on AuditAnchorV2 with an
///              `execCommitment` binding this market and an authorised ceiling,
///              and must not have executed it before (same binding discipline
///              as the vault)
///           2. pull `assets` of the market's loan token from the caller
///           3. supply them to Morpho ON BEHALF OF THE CALLER, so the user
///              directly owns the Morpho supply position (non-custodial —
///              they withdraw straight from Morpho, not from this adapter)
///           4. assert the adapter retains no loan-token dust; emit Supplied
///
/// @dev    Both the set of loan tokens AND the set of target markets are
///         frozen at construction, so the trust boundary is immutable — to
///         add a market, deploy a new adapter.
contract MorphoSupplyAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IMorpho     public immutable MORPHO;
    AuditAnchorV2 public immutable ANCHOR;

    /// @notice Loan tokens this adapter is permitted to supply. Frozen at deploy.
    mapping(address => bool) public isApprovedLoanToken;

    /// @notice (user, orderHash) => already executed. (Audit M-6.)
    mapping(address => mapping(bytes32 => bool)) public consumed;

    /// @notice Morpho market ids this adapter is permitted to supply into,
    ///         frozen at deploy. Without this, `collateralToken`, `oracle`,
    ///         `irm` and `lltv` are entirely caller-supplied: a hostile
    ///         frontend could route a user's approved loan tokens into an
    ///         attacker-created market with a worthless oracle while the
    ///         `Supplied` event still looked legitimate. (Audit M-4.)
    mapping(bytes32 => bool) public isApprovedMarket;

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
    error ExecutionNotAnchored(bytes32 expected, bytes32 got);
    error AnchorAlreadyConsumed(bytes32 orderHash);
    error AssetsExceedAuthorised(uint256 assets, uint256 maxAssets);
    error LoanTokenNotApproved(address token);
    error MarketNotApproved(bytes32 marketId);
    error DustResidual(uint256 amount);

    constructor(
        address _morpho,
        address _anchor,
        address[] memory _approvedLoanTokens,
        bytes32[] memory _approvedMarkets
    ) {
        MORPHO = IMorpho(_morpho);
        ANCHOR = AuditAnchorV2(_anchor);
        for (uint256 i = 0; i < _approvedLoanTokens.length; ++i) {
            isApprovedLoanToken[_approvedLoanTokens[i]] = true;
        }
        for (uint256 i = 0; i < _approvedMarkets.length; ++i) {
            isApprovedMarket[_approvedMarkets[i]] = true;
        }
    }

    /// @notice The execution commitment for a supply call. Binds the caller,
    ///         the exact market, and the maximum assets authorised.
    /// @dev    `maxAssets` is a CEILING rather than an exact amount because the
    ///         yield leg is chained off the swap leg: the agent cannot know the
    ///         precise swap output at signing time. Binding the ceiling keeps
    ///         the authorisation bounded while allowing the realised amount to
    ///         float below it.
    function supplyCommitment(address user, MarketParams memory params, uint256 maxAssets)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(user, params, maxAssets));
    }

    /// @notice Supply `assets` of `params.loanToken` into the Morpho market
    ///         `params`, on behalf of the caller.
    /// @param  orderHash SHA-256 of the canonical PQ-signed order. The caller
    ///                   must have anchored it on AuditAnchorV2 with
    ///                   `execCommitment == supplyCommitment(...)`, and must
    ///                   not have executed it already.
    /// @param  params    the Morpho Blue market to supply into.
    /// @param  assets    amount of the loan token to supply (exact assets).
    /// @param  maxAssets the authorised ceiling committed to at anchor time.
    /// @return shares    supply shares credited to the caller by Morpho.
    function supply(
        bytes32 orderHash,
        MarketParams calldata params,
        uint256 assets,
        uint256 maxAssets
    )
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAssets();
        if (orderHash == bytes32(0)) revert ZeroHash();
        if (assets > maxAssets) revert AssetsExceedAuthorised(assets, maxAssets);

        // Provenance: the anchor must commit to exactly this market and ceiling.
        bytes32 anchored = ANCHOR.execCommitmentOf(msg.sender, orderHash);
        if (anchored == bytes32(0)) revert AnchorNotFound(orderHash);
        bytes32 expected = supplyCommitment(msg.sender, params, maxAssets);
        if (anchored != expected) revert ExecutionNotAnchored(expected, anchored);

        // One anchor authorises exactly one supply.
        if (consumed[msg.sender][orderHash]) revert AnchorAlreadyConsumed(orderHash);
        consumed[msg.sender][orderHash] = true;

        if (!isApprovedLoanToken[params.loanToken]) revert LoanTokenNotApproved(params.loanToken);

        // Morpho's market id is keccak256 over the five market params, so this
        // pins the oracle, IRM, LLTV and collateral token as well as the loan
        // token — the caller cannot redirect funds to a market we never vetted.
        bytes32 marketId = keccak256(abi.encode(params));
        if (!isApprovedMarket[marketId]) revert MarketNotApproved(marketId);

        IERC20 loan = IERC20(params.loanToken);

        // Snapshot BEFORE pulling. The dust invariant below is relative to
        // this, not against zero: ERC-20 transfers are push-based, so anyone
        // can donate dust to this adapter unsolicited. An absolute
        // `balanceOf(this) == 0` check would let a 1-unit donation brick every
        // future call permanently (no owner, no rescue path). Donated dust is
        // now inert — it simply sits here, untouched.
        uint256 balBefore = loan.balanceOf(address(this));

        loan.safeTransferFrom(msg.sender, address(this), assets);
        loan.forceApprove(address(MORPHO), assets);

        // onBehalf = msg.sender: the user owns the supply position directly.
        (, shares) = MORPHO.supply(params, assets, 0, msg.sender, "");

        // Reset the allowance and assert everything pulled was supplied: our
        // balance must be exactly what it was on entry.
        loan.forceApprove(address(MORPHO), 0);
        uint256 balAfter = loan.balanceOf(address(this));
        if (balAfter != balBefore) {
            revert DustResidual(
                balAfter > balBefore ? balAfter - balBefore : balBefore - balAfter
            );
        }

        emit Supplied(msg.sender, orderHash, marketId, params.loanToken, assets, shares);
    }
}
