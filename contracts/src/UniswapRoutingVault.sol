// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 }         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }      from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IV3SwapRouter }  from "./interfaces/IV3SwapRouter.sol";
import { IWrappedNative } from "./interfaces/IWrappedNative.sol";
import { AuditAnchorV2 }  from "./AuditAnchorV2.sol";

/// @title  UniswapRoutingVault — agent-driven executor that routes native
///         MON into DeFi tokens through the REAL Uniswap v3 SwapRouter02.
/// @notice Successor to RoutingVault (which routed through the in-repo
///         MiniAMM mock). This version executes the agent's PQ-signed,
///         on-chain-anchored allocation against production Uniswap v3
///         pools on Monad mainnet.
///
///         Flow per call:
///           1. caller must have anchored `orderHash` on AuditAnchorV2 with an
///              `execCommitment` equal to keccak256 over exactly these call
///              parameters, and must not have executed it before. This binds
///              the trade to the off-chain QPU result + PQ signature: the
///              signed order contains the execution fields, so the ML-DSA
///              signature covers what actually executes.
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
///           * fee tiers are allowlisted, zero-weight legs are rejected (they
///             would hit SwapRouter02's CONTRACT_BALANCE sentinel), and a
///             zero `amountOutMin` is rejected as fail-open slippage.
contract UniswapRoutingVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IWrappedNative public immutable WRAPPED_MON;
    IV3SwapRouter  public immutable ROUTER;
    AuditAnchorV2  public immutable ANCHOR;

    /// @notice Output tokens this vault is permitted to route into. Frozen
    ///         at construction to keep the trust boundary immutable — to
    ///         add a token, deploy a new vault.
    mapping(address => bool) public isApprovedToken;

    /// @notice Uniswap v3 fee tiers this vault may route through, frozen at
    ///         deploy. The fee tier selects the POOL, and sibling pools on the
    ///         same pair can be near-empty: on Monad mainnet the WMON/USDC
    ///         0.05% pool held 2.93 USDC and the 0.01% pool 0.19 USDC against
    ///         447k in the 0.3% pool. Routing into one of those is an 88-99%
    ///         loss, and `amountOutMin` alone cannot defend it because that is
    ///         caller-supplied too. (Audit H-3.)
    mapping(uint24 => bool) public isApprovedFeeTier;

    /// @notice (user, orderHash) => already executed. An anchor authorises
    ///         exactly one execution; without this a single anchor authorised
    ///         unlimited divergent trades. (Audit M-6.)
    mapping(address => mapping(bytes32 => bool)) public consumed;

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
    error ExecutionNotAnchored(bytes32 expected, bytes32 got);
    error AnchorAlreadyConsumed(bytes32 orderHash);
    error FeeTierNotApproved(uint256 idx, uint24 fee);
    error ZeroWeightLeg(uint256 idx);
    error ZeroWeightBps(uint256 idx);
    error ZeroSlippageFloor(uint256 idx);
    error WMonDustResidual(uint256 amount);

    constructor(
        address _wmon,
        address _router,
        address _anchor,
        address[] memory _approvedTokens,
        uint24[]  memory _approvedFeeTiers
    ) {
        WRAPPED_MON = IWrappedNative(_wmon);
        ROUTER      = IV3SwapRouter(_router);
        ANCHOR      = AuditAnchorV2(_anchor);
        for (uint256 i = 0; i < _approvedTokens.length; ++i) {
            isApprovedToken[_approvedTokens[i]] = true;
        }
        for (uint256 i = 0; i < _approvedFeeTiers.length; ++i) {
            isApprovedFeeTier[_approvedFeeTiers[i]] = true;
        }
    }

    /// @notice The execution commitment for a routing call. The agent computes
    ///         this over the same fields inside the PQ-signed order, so the
    ///         ML-DSA signature covers exactly what executes on chain.
    ///
    /// @dev    `amountOutMin` and `deadline` are INSIDE the commitment on
    ///         purpose. They are the two parameters that decide economic loss,
    ///         and leaving them free let the broadcasting ECDSA key deviate
    ///         from PQ-signed intent — submitting `amountOutMin = 1` against an
    ///         order that specified a real floor, or replaying a long-expired
    ///         order with a fresh deadline, while the chain still showed a
    ///         correctly-anchored trade. That broke the two-key custody claim
    ///         ("PQ key authorises intent, ECDSA key authorises execution").
    ///         (Audit M-7.)
    ///
    /// @dev    Takes `memory` so off-chain builders, tests and the executor all
    ///         go through ONE implementation — two parallel calldata/memory
    ///         copies would be a place for the commitment to silently diverge.
    ///         `abi.encode` (never `encodePacked`) is load-bearing: packed
    ///         encoding drops array length prefixes, so feeTiers=[3000,500] with
    ///         weights=[10000] collides with feeTiers=[3000], weights=[500,10000].
    /// @dev    DOMAIN SEPARATION: `block.chainid` and `address(this)` lead the
    ///         preimage. Without them the commitment identified neither the
    ///         chain nor the executor, while `consumed` is per-executor
    ///         storage — so one anchor was spendable once on EVERY vault
    ///         sharing this AuditAnchorV2, which is the documented upgrade
    ///         path ("to add a token, deploy a new vault"), and again on every
    ///         chain the contracts are deployed to. (Audit RT08 / pipeline-2.)
    function routeCommitment(
        bytes32   orderHash,
        address   user,
        address[] memory tokenOuts,
        uint24[]  memory feeTiers,
        uint16[]  memory weightsBps,
        uint256   amountInWei,
        uint256[] memory amountOutMin,
        uint256   deadline
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid, address(this), orderHash, user, tokenOuts,
                feeTiers, weightsBps, amountInWei, amountOutMin, deadline
            )
        );
    }

    /// @notice Execute the agent's allocation: wrap MON, then for each pool
    ///         swap its weighted slice into `tokenOuts[i]` via Uniswap v3.
    /// @param  orderHash     SHA-256 of the canonical PQ-signed order. The
    ///                       caller must have anchored it on AuditAnchorV2
    ///                       with `execCommitment == routeCommitment(...)`
    ///                       over these exact arguments, and must not have
    ///                       executed it already. Anchors are keyed per
    ///                       (anchorer, orderHash), so orders may be
    ///                       pipelined without stranding each other.
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
        // Provenance: the caller must have anchored this exact order AND the
        // anchor must commit to exactly these execution parameters.
        bytes32 anchored = ANCHOR.execCommitmentOf(msg.sender, orderHash);
        if (anchored == bytes32(0)) revert AnchorNotFound(orderHash);
        bytes32 expected = routeCommitment(
            orderHash, msg.sender, tokenOuts, feeTiers, weightsBps,
            msg.value, amountOutMin, deadline
        );
        if (anchored != expected) revert ExecutionNotAnchored(expected, anchored);

        // One anchor authorises exactly one execution.
        if (consumed[msg.sender][orderHash]) revert AnchorAlreadyConsumed(orderHash);
        consumed[msg.sender][orderHash] = true;

        uint256 sum;
        for (uint256 i = 0; i < n; ++i) sum += weightsBps[i];
        if (sum != 10_000) revert WeightsDoNotSumTo10000(sum);

        // Snapshot our WMON balance BEFORE wrapping. The dust invariant below
        // is asserted relative to this, not against zero: WMON transfers are
        // push-based, so anyone can donate dust to this contract unsolicited.
        // An absolute `balanceOf(this) == 0` check would let a 1-wei donation
        // brick every future call permanently (no owner, no rescue path).
        // Donated dust is now inert — it simply sits here, untouched.
        uint256 balBefore = IERC20(address(WRAPPED_MON)).balanceOf(address(this));

        // Wrap the whole deposit, then approve the router for exactly it.
        WRAPPED_MON.deposit{value: msg.value}();
        IERC20(address(WRAPPED_MON)).forceApprove(address(ROUTER), msg.value);

        uint256[] memory amountsOut = new uint256[](n);
        uint256 remaining = msg.value;
        for (uint256 i = 0; i < n; ++i) {
            if (!isApprovedToken[tokenOuts[i]]) {
                revert TokenNotApproved(i, tokenOuts[i]);
            }
            if (!isApprovedFeeTier[feeTiers[i]]) {
                revert FeeTierNotApproved(i, feeTiers[i]);
            }
            // An unbounded slippage floor is a fail-open on a thin pool.
            // (Audit L-2.)
            if (amountOutMin[i] == 0) revert ZeroSlippageFloor(i);

            // A zero-weight leg is a contradiction in the ORDER: the signed
            // allocation says "route none of the deposit here", yet names a
            // token, a fee tier and a slippage floor for it. Rejecting it is a
            // semantic assertion about intent, and it is NOT subsumed by the
            // quantity guard below: on the last leg `amountIn` is the rounding
            // remainder, so `weights = [5000, 5000, 0]` on a 3-wei deposit
            // gives the zero-weight leg 1 wei of dust, clears `amountIn != 0`,
            // and executes a real swap against a slice the order weighted at
            // zero — recording output in `Routed` that the order never
            // authorised. Value at risk is under n wei, but the on-chain
            // record IS the product here. (Audit RT07h.)
            if (weightsBps[i] == 0) revert ZeroWeightBps(i);

            // Last leg absorbs the rounding remainder so the full deposit
            // is deployed and no WMON dust is stranded.
            uint256 amountIn = i == n - 1
                ? remaining
                : (msg.value * weightsBps[i]) / 10_000;

            // Guard the QUANTITY, not the weight. SwapRouter02 reads
            // `amountIn == 0` as its CONTRACT_BALANCE sentinel: it swaps its
            // OWN inventory and pays from itself, laundering that output into
            // a hash-anchored Routed event against a slice the caller never
            // funded. Checking `weightsBps[i] == 0` did NOT implement that
            // invariant — integer division floors a perfectly legal 1-bp
            // weight to zero whenever `msg.value * weightsBps[i] < 10_000`,
            // i.e. for any deposit of 9_999 wei or less, with the weights
            // still summing to 10_000 and the anchored commitment still
            // matching. (Audit M-5, reopened as RT07.)
            if (amountIn == 0) revert ZeroWeightLeg(i);
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

        // Clear the standing approval and assert the full deposit was routed:
        // our balance must be exactly what it was on entry. If the router ever
        // pulled less than we approved, this catches it.
        IERC20(address(WRAPPED_MON)).forceApprove(address(ROUTER), 0);
        uint256 balAfter = IERC20(address(WRAPPED_MON)).balanceOf(address(this));
        if (balAfter != balBefore) {
            revert WMonDustResidual(
                balAfter > balBefore ? balAfter - balBefore : balBefore - balAfter
            );
        }

        emit Routed(
            msg.sender, orderHash, msg.value, tokenOuts, feeTiers, amountsOut, weightsBps
        );
    }

    /// @notice Reject naked sends — every MON inflow must carry an orderHash.
    receive() external payable {
        revert ZeroHash();
    }
}
