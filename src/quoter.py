"""Live on-chain quotes from Uniswap v3 QuoterV2 on Monad mainnet.

Why this module exists
----------------------
`amountOutMin` is the entire MEV defence for a routed order. Once the vault
binds execution to a signed commitment, nothing downstream can widen or narrow
that floor — so the number chosen at signing time is the number the trade lives
with. Deriving it from a hardcoded reference rate is a time bomb in both
directions:

  * too low  — a sandwich extracting up to the accumulated drift lands and is
               recorded as a correctly anchored, correctly executed trade;
  * too high — every order reverts on the live pool until the deadline passes
               and burns the anchor.

Both were observed. A rate captured on 2026-07-28 was accurate to +0.004% at
capture and had drifted -1.17% six hours later, which was enough to push a
50 bps floor below the live quote and revert every order.

QuoterV2 (address verified on-chain 2026-07-29: `factory()` and `WETH9()` match
the same UniswapV3Factory and WMON that UniswapRoutingVault is wired to) prices
the swap through real pool depth rather than spot, so it accounts for the price
impact the order itself causes.

Note QuoterV2 is NOT a view function — it executes the swap and reverts to
return the result — so it must be reached with `eth_call`, never a transaction.
"""

from __future__ import annotations

import json
import urllib.request

# Uniswap v3 on Monad mainnet (chainId 143). Cross-checked against
# developers.uniswap.org and verified on-chain.
QUOTER_V2_MAINNET = "0x661E93cCa42afaCB172121Ef892830Ca3B70F08d"
MONAD_MAINNET_CHAIN_ID = 143

# quoteExactInputSingle((address,address,uint256,uint24,uint160))
_QUOTE_SELECTOR = bytes.fromhex("c6a5026a")

_DEFAULT_RPC = "https://rpc.monad.xyz"


class QuoteError(RuntimeError):
    """Raised when a live quote cannot be obtained. Never fall back to a
    hardcoded rate on this — refuse to sign instead."""


def _word(v: int) -> bytes:
    if isinstance(v, bool):
        raise TypeError("bool is not a uint256")
    if v < 0 or v >= 2 ** 256:
        raise ValueError(f"value does not fit in uint256: {v}")
    return v.to_bytes(32, "big")


def _addr_word(a: str) -> bytes:
    if not isinstance(a, str) or not a.startswith("0x") or len(a) != 42:
        raise ValueError(f"not a 20-byte hex address: {a!r}")
    return bytes(12) + bytes.fromhex(a[2:])


def _rpc_call(rpc_url: str, to: str, data: bytes, timeout: int) -> bytes:
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_call",
        "params": [{"to": to, "data": "0x" + data.hex()}, "latest"],
    }).encode()
    req = urllib.request.Request(
        rpc_url, data=payload, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read())
    except Exception as exc:                       # network, DNS, timeout, 5xx
        raise QuoteError(f"quote RPC call failed: {exc}") from exc

    if "error" in body:
        raise QuoteError(f"quote reverted on-chain: {body['error']}")
    result = body.get("result")
    if not isinstance(result, str) or not result.startswith("0x"):
        raise QuoteError(f"malformed RPC result: {result!r}")
    return bytes.fromhex(result[2:])


def quote_exact_input_single(
    token_in: str,
    token_out: str,
    amount_in_wei: int,
    fee: int,
    *,
    rpc_url: str = _DEFAULT_RPC,
    quoter: str = QUOTER_V2_MAINNET,
    timeout: int = 20,
) -> int:
    """Return amountOut for an exact-input single-hop swap, priced live.

    Args:
        token_in: input token address (WMON for a native-MON route).
        token_out: output token address.
        amount_in_wei: exact input amount, in token_in's smallest unit.
        fee: pool fee tier in hundredths of a bip (500 / 3000 / 10000).
        rpc_url: Monad mainnet JSON-RPC endpoint.
        quoter: QuoterV2 address; defaults to the verified mainnet deployment.
        timeout: seconds to wait for the node.

    Returns:
        amountOut in token_out's smallest unit.

    Raises:
        QuoteError: if the node is unreachable, the call reverts (no pool at
            that fee tier, or insufficient liquidity), or the response is
            malformed. Callers must NOT substitute a hardcoded rate.
    """
    if amount_in_wei <= 0:
        raise ValueError(f"amount_in_wei must be positive, got {amount_in_wei}")
    if fee not in (500, 3000, 10_000):
        raise ValueError(f"fee must be one of 500/3000/10000, got {fee}")

    data = (
        _QUOTE_SELECTOR
        + _addr_word(token_in)
        + _addr_word(token_out)
        + _word(amount_in_wei)
        + _word(fee)
        + _word(0)                                 # sqrtPriceLimitX96: no limit
    )
    ret = _rpc_call(rpc_url, quoter, data, timeout)

    # (uint256 amountOut, uint160 sqrtPriceX96After,
    #  uint32 initializedTicksCrossed, uint256 gasEstimate)
    if len(ret) < 128:
        raise QuoteError(
            f"quoter returned {len(ret)} bytes, expected >= 128. The address "
            "may not be a QuoterV2."
        )
    amount_out = int.from_bytes(ret[0:32], "big")
    if amount_out == 0:
        raise QuoteError(
            "quoter returned amountOut == 0 — no usable liquidity in that pool. "
            "Refusing to derive a slippage floor from it."
        )
    return amount_out
