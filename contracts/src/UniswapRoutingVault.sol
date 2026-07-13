// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 }         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }      from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IV3SwapRouter }  from "./interfaces/IV3SwapRouter.sol";
import { IWrappedNative } from "./interfaces/IWrappedNative.sol";
import { AuditAnchor }    from "./AuditAnchor.sol";

/// @title  UniswapRoutingVault — agent-driven executor that routes native
///         MON into DeFi tokens through the REAL Uniswap v3 SwapRouter02.
/// @notice Successor to RoutingVault (which routed through the in-repo
///         MiniAMM mock). This version executes the agent's PQ-signed,
///         on-chain-anchored allocation against production Uniswap v3
///         pools on Monad mainnet.
///
///         Flow per call:
///           1. caller must have most-recently anchored `orderHash` on
///              AuditAnchor (provenance gate — links this trade to the
///              off-chain QPU result + PQ signature)
///           2. wrap msg.value MON -> WMON
///           3. for each pool: swap the weighted slice WMON -> tokenOut
///              via SwapRouter02.exactInputSingle, delivering the output
///              straight to the caller with real slippage protection
///           4. assert no WMON dust is retained; emit Routed
///
/// @dev    Design deltas vs the MiniAMM-era RoutingVault, all deliberate:
///           * `amountOutMin[i]` is now a TRUE minimum (Uniswap returns the
///             real output, which is >= min). The old vault handed the user
///             EXACTLY the minimum and donated any favourable slippage to
///             LPs — an economic leak for the user. (Audit H-1.)
///           * routing target is (tokenOut, feeTier) not a pair address;
///             the canonical pool is resolved by SwapRouter02 via the V3
///             factory, so pair-impersonation is impossible by construction.
///           * an immutable `isApprovedToken` allowlist freezes the tradable
///             universe per deployment (mirrors the old pair allowlist).
///           * a `deadline` param gives explicit MEV / stale-tx protection,
///             which SwapRouter02's struct no longer carries.
contract UniswapRoutingVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IWrappedNative public immutable WRAPPED_MON;
    IV3SwapRouter  public immutable ROUTER;
    AuditAnchor    public immutable ANCHOR;

    /// @notice Output tokens this vault is permitted to route into. Frozen
    ///         at construction to keep the trust boundary immutable — to
    ///         add a token, deploy a new vault.
    mapping(address => bool) public isApprovedToken;

    event Routed(
        address indexed user,
        bytes32 indexed orderHash,
        uint256 amountInWei,
        address[] tokenOuts,
        uint24[]  feeTiers,
        uint256[] amountsOut,
        uint16[]  weightsBps
    );

    error ZeroValue();
    error ZeroHash();
    error LengthMismatch(uint256 n);
    error WeightsDoNotSumTo10000(uint256 sum);
    error DeadlinePassed(uint256 deadline, uint256 nowTs);
    error TokenNotApproved(uint256 idx, address token);
    error AnchorNotFound(bytes32 expected);
    error WMonDustResidual(uint256 amount);

    constructor(
        address _wmon,
        address _router,
        address _anchor,
        address[] memory _approvedTokens
    ) {
        WRAPPED_MON = IWrappedNative(_wmon);
        ROUTER      = IV3SwapRouter(_router);
        ANCHOR      = AuditAnchor(_anchor);
        for (uint256 i = 0; i < _approvedTokens.length; ++i) {
            isApprovedToken[_approvedTokens[i]] = true;
        }
    }

    /// @notice Execute the agent's allocation: wrap MON, then for each pool
    ///         swap its weighted slice into `tokenOuts[i]` via Uniswap v3.
    /// @param  orderHash     SHA-256 of the canonical PQ-signed order. MUST
    ///                       equal AuditAnchor.lastHash[msg.sender] — i.e.
    ///                       the caller anchored this exact hash most
    ///                       recently. Sequencing contract: anchor(order N)
    ///                       then route(order N) with no intervening anchor.
    /// @param  tokenOuts     output ERC20 per pool; each must be approved.
    /// @param  feeTiers      Uniswap v3 fee tier per pool (500 / 3000 / 10000).
    /// @param  weightsBps    basis-points weight per pool (sum == 10_000).
    /// @param  amountOutMin  minimum tokenOut per pool — real slippage floor
    ///                       passed straight to the router; the swap reverts
    ///                       if the pool can't fill it.
    /// @param  deadline      unix seconds; reverts if block.timestamp exceeds.
    function executeAndRoute(
        bytes32 orderHash,
        address[] calldata tokenOuts,
        uint24[]  calldata feeTiers,
        uint16[]  calldata weightsBps,
        uint256[] calldata amountOutMin,
        uint256 deadline
    ) external payable nonReentrant {
        if (msg.value == 0) revert ZeroValue();
        if (orderHash == bytes32(0)) revert ZeroHash();
        if (block.timestamp > deadline) revert DeadlinePassed(deadline, block.timestamp);

        uint256 n = tokenOuts.length;
        if (
            n == 0 ||
            n != feeTiers.length ||
            n != weightsBps.length ||
            n != amountOutMin.length
        ) {
            revert LengthMismatch(n);
        }
        if (ANCHOR.lastHash(msg.sender) != orderHash) {
            revert AnchorNotFound(orderHash);
        }
        uint256 sum;
        for (uint256 i = 0; i < n; ++i) sum += weightsBps[i];
        if (sum != 10_000) revert WeightsDoNotSumTo10000(sum);

        // Wrap the whole deposit, then approve the router for exactly it.
        WRAPPED_MON.deposit{value: msg.value}();
        IERC20(address(WRAPPED_MON)).forceApprove(address(ROUTER), msg.value);

        uint256[] memory amountsOut = new uint256[](n);
        uint256 remaining = msg.value;
        for (uint256 i = 0; i < n; ++i) {
            if (!isApprovedToken[tokenOuts[i]]) {
                revert TokenNotApproved(i, tokenOuts[i]);
            }
            // Last leg absorbs the rounding remainder so the full deposit
            // is deployed and no WMON dust is stranded.
            uint256 amountIn = i == n - 1
                ? remaining
                : (msg.value * weightsBps[i]) / 10_000;
            remaining -= amountIn;

            amountsOut[i] = ROUTER.exactInputSingle(
                IV3SwapRouter.ExactInputSingleParams({
                    tokenIn:           address(WRAPPED_MON),
                    tokenOut:          tokenOuts[i],
                    fee:               feeTiers[i],
                    recipient:         msg.sender,
                    amountIn:          amountIn,
                    amountOutMinimum:  amountOutMin[i],
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // Clear the standing approval and assert we hold no WMON. If the
        // router ever pulled less than we approved, this catches it.
        IERC20(address(WRAPPED_MON)).forceApprove(address(ROUTER), 0);
        uint256 residual = IERC20(address(WRAPPED_MON)).balanceOf(address(this));
        if (residual != 0) revert WMonDustResidual(residual);

        emit Routed(
            msg.sender, orderHash, msg.value, tokenOuts, feeTiers, amountsOut, weightsBps
        );
    }

    /// @notice Reject naked sends — every MON inflow must carry an orderHash.
    receive() external payable {
        revert ZeroHash();
    }
}
