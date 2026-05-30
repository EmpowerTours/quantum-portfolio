// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { MiniAMM } from "./dex/MiniAMM.sol";
import { WMON }    from "./dex/WMON.sol";
import { AuditAnchor } from "./AuditAnchor.sol";

/// @title  RoutingVault — agent-driven on-chain swap executor (hardened v2)
/// @notice Upgrade over MonadAllocationVault that EXECUTES the agent's
///         recommended allocation by swapping native MON into test ERC20
///         tokens via MiniAMM pairs.
/// @dev    Hardened against findings from the second-round audit (2026-05-30):
///           - amountOutMin from caller (kills quote-then-swap sandwich-DoS)
///           - anchor-existence check against AuditAnchor.lastHash
///           - allowlist of approved pairs (rejects fake-pair impersonation)
///           - ReentrancyGuard on the entry point
///           - post-loop WMON.balanceOf invariant
///           - event renamed Routed (was Allocated) to avoid collision with
///             MonadAllocationVault's Allocated event
contract RoutingVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    WMON         public immutable WRAPPED_MON;
    AuditAnchor  public immutable ANCHOR;

    /// @notice Approved MiniAMM pair contracts. Set in constructor;
    ///         immutable per deployment to keep the trust boundary
    ///         frozen. To support a new pair, deploy a new RoutingVault.
    mapping(address => bool) public isApprovedPair;

    event Routed(
        address indexed user,
        bytes32 indexed orderHash,
        uint256 amountInWei,
        address[] tokenOuts,
        uint256[] amountsOut,
        uint16[]  weightsBps
    );

    error ZeroValue();
    error ZeroHash();
    error LengthMismatch(uint256 n);
    error WeightsDoNotSumTo10000(uint256 sum);
    error UnknownPair(uint256 idx);
    error InvalidPairTokens(uint256 idx);
    error AnchorNotFound(bytes32 expected);
    error WMonDustResidual(uint256 amount);

    constructor(address payable _wmon, address _anchor, address[] memory _approvedPairs) {
        WRAPPED_MON = WMON(_wmon);
        ANCHOR = AuditAnchor(_anchor);
        for (uint256 i = 0; i < _approvedPairs.length; ++i) {
            isApprovedPair[_approvedPairs[i]] = true;
        }
    }

    /// @notice Execute the agent's allocation: deposit MON, swap each
    ///         weighted portion through an approved MiniAMM, deliver
    ///         output tokens to msg.sender. Slippage protection is the
    ///         caller-supplied `amountOutMin[]` (not an on-chain quote)
    ///         so the swap is sandwich-resistant: if reserves move
    ///         against the user, the pair's k-check reverts; if they
    ///         move with the user, surplus stays in the pool (LP win).
    /// @param  orderHash      SHA-256 of the canonical PQ-signed order.
    ///                        Must equal AuditAnchor.lastHash[msg.sender]
    ///                        — i.e. the caller must have anchored this
    ///                        exact hash most recently. (Audit fix #2.)
    /// @param  tokenOuts      each pool's output ERC20 address
    /// @param  pairs          MiniAMM pair to route through; must be in
    ///                        isApprovedPair (audit fix #8 / L-2)
    /// @param  weightsBps     basis-points weight per pool (sum = 10_000)
    /// @param  amountOutMin   minimum tokens out per swap. Used DIRECTLY
    ///                        as the swap's amount0Out/amount1Out arg;
    ///                        the AMM reverts on insufficient k if the
    ///                        user's minimum is unsatisfiable at current
    ///                        reserves. (Audit fix H-2.)
    function executeAndRoute(
        bytes32 orderHash,
        address[] calldata tokenOuts,
        address[] calldata pairs,
        uint16[]  calldata weightsBps,
        uint256[] calldata amountOutMin
    ) external payable nonReentrant {
        if (msg.value == 0) revert ZeroValue();
        if (orderHash == bytes32(0)) revert ZeroHash();
        uint256 n = tokenOuts.length;
        if (n == 0 || n != pairs.length || n != weightsBps.length || n != amountOutMin.length) {
            revert LengthMismatch(n);
        }
        if (ANCHOR.lastHash(msg.sender) != orderHash) {
            revert AnchorNotFound(orderHash);
        }
        uint256 sum;
        for (uint256 i = 0; i < n; ++i) sum += weightsBps[i];
        if (sum != 10_000) revert WeightsDoNotSumTo10000(sum);

        WRAPPED_MON.deposit{value: msg.value}();

        uint256[] memory amountsOut = new uint256[](n);
        uint256 remaining = msg.value;
        for (uint256 i = 0; i < n; ++i) {
            if (!isApprovedPair[pairs[i]]) revert UnknownPair(i);
            uint256 amountIn = i == n - 1
                ? remaining
                : (msg.value * weightsBps[i]) / 10_000;
            remaining -= amountIn;

            MiniAMM pair = MiniAMM(pairs[i]);
            IERC20 t0 = pair.token0();
            IERC20 t1 = pair.token1();
            bool wmonIsToken0 = address(WRAPPED_MON) == address(t0);
            if (!wmonIsToken0 && address(WRAPPED_MON) != address(t1)) {
                revert InvalidPairTokens(i);
            }
            IERC20 tokenOutInPair = wmonIsToken0 ? t1 : t0;
            if (address(tokenOutInPair) != tokenOuts[i]) revert InvalidPairTokens(i);

            // Push WMON in. swap() reverts on InvalidK if reserves don't
            // support the requested amountOutMin — that's our slippage guard.
            IERC20(address(WRAPPED_MON)).safeTransfer(address(pair), amountIn);
            if (wmonIsToken0) {
                pair.swap(0, amountOutMin[i], msg.sender);
            } else {
                pair.swap(amountOutMin[i], 0, msg.sender);
            }
            amountsOut[i] = amountOutMin[i];
        }

        // Invariant: vault MUST NOT retain any WMON dust. If it does, a
        // future caller could capture it for free. (Audit fix #7.)
        uint256 residual = IERC20(address(WRAPPED_MON)).balanceOf(address(this));
        if (residual != 0) revert WMonDustResidual(residual);

        emit Routed(msg.sender, orderHash, msg.value, tokenOuts, amountsOut, weightsBps);
    }

    /// @notice Reject naked sends — every MON inflow must come with an
    ///         orderHash via executeAndRoute.
    receive() external payable {
        revert ZeroHash();
    }
}
