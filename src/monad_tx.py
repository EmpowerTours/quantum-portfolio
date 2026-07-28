"""Construct an unsigned Monad rebalance transaction from a signed order.

Turns a PQ-signed `SignedOrder` into a wallet-ready unsigned EIP-1559
transaction. The `data` field carries the order + post-quantum signature
+ public key, so the on-chain audit record links to the off-chain QPU
result.

Three modes shipped:

  1. Self-transfer-with-payload — the agent sends 0 MON to itself with
     the signed order encoded in calldata (~5 KB on-chain). Heavy but
     reviewer-readable: the entire signed order + the three signatures
     + the three public keys land on-chain in one TX.
     → `build_unsigned_tx`

  2. AuditAnchor.anchor — calls the deployed AuditAnchor contract with
     the 32-byte SHA-256 of the signed order. ~30 K gas (vs ~75 K for
     option 1). Contract is live on Monad testnet at
     0x0e649C383CFA6be1998445D0A7a8E1cc7540D239 (Monadscan-verified).
     → `build_anchor_tx`

  3. MonadAllocationVault.execute — deposits native MON under the
     signed order hash and emits an `Allocated` event. A separate
     RoutingVault + MiniAMM stack in contracts/ demonstrates the
     routed-trade path on testnet; this module currently builds the
     anchor and allocation-vault transactions used by the shipped
     reproducibility artefacts.

The transaction is NOT signed with ECDSA here. A wallet (MetaMask, a
custodian, or web3.py) signs and broadcasts it. That intentional
separation means: the agent's PQ key authorises the INTENT, the
wallet's ECDSA key authorises the EXECUTION. Two-key custody.
"""
from __future__ import annotations

import re

import base64
import json
from dataclasses import dataclass
from typing import Any

from . import pq_signing as pq
from .orders import (
    RouteExecution, SignedOrder, SupplyExecution, TrustedKeys, verify_signed_order,
)


_ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")


def _require_address(a: str, what: str) -> None:
    """Reject anything that is not exactly 20 hex bytes.

    The previous checks were `startswith("0x") and len(...) == 42`, which
    accepted arbitrary non-hex garbage — `0xZZZZ...`, SQL fragments, and
    whitespace-padded strings all passed and were copied verbatim into the
    serialised transaction. `cast` rejects the same inputs, so the
    hand-rolled encoder was strictly weaker than the reference tooling.
    """
    if not isinstance(a, str) or not _ADDRESS_RE.match(a):
        raise ValueError(f"{what} must be a 0x-prefixed 20-byte hex address: {a!r}")
    if len(bytes.fromhex(a[2:])) != 20:
        raise ValueError(f"{what} decoded to the wrong length: {a!r}")


class UnverifiableOrder(ValueError):
    """Raised by any builder when a SignedOrder fails signature verification.

    Cross-system audit finding #10: pre-fix `build_*_tx` and
    `encode_order_calldata` would happily produce calldata from a
    tampered `outputs/signed_orders.json` — a remote attacker who
    writes to the file (or a fresh-clone reviewer running on a
    poisoned artefact) could anchor a forged SHA-256 on-chain. Every
    public builder now verifies before serialising; the signature is
    the load-bearing trust boundary.
    """


def _verify_or_raise(
    signed: SignedOrder,
    *,
    trusted: TrustedKeys | None = None,
    require_hedged: bool = True,
) -> None:
    """Gate every builder on an explicit verification POLICY.

    `trusted` pins the agent public keys, so a tampered artefact carrying an
    attacker's own keypair is rejected rather than verified against itself
    (audit M-1). Pass it from any caller that will act on the result — the
    docstring on `UnverifiableOrder` claims to defend against exactly that
    attacker, and without pinning it does not.

    `require_hedged` defaults to True because every production artefact is
    triple-signed; single-leg ML-DSA orders are a legacy path and must opt
    out explicitly rather than being silently accepted (audit Z-2).
    """
    if not verify_signed_order(signed, trusted=trusted, require_hedged=require_hedged):
        raise UnverifiableOrder(
            f"signed order {signed.order.order_id} fails PQ signature "
            "verification — refusing to build calldata that would "
            "anchor an un-attested hash on-chain. If the artefact was "
            "regenerated cleanly via run_pq_demo.py the embedded "
            "signature should verify; if it does not, the artefact "
            "is tampered or corrupted."
        )

# Monad chain IDs (verify at https://docs.monad.xyz/developer-essentials).
# We keep mainnet as the default so a copy-paste typo to testnet fails
# the chain-id-locked unit test (test_chain_id_is_monad_mainnet) instead
# of silently broadcasting on the wrong network.
MONAD_CHAIN_ID         = 143      # mainnet — default for builders
MONAD_TESTNET_CHAIN_ID = 10143    # testnet — pass explicitly via chain_id=

# Defaults tuned for cheap Monad fees as of 2026-05; override per call.
DEFAULT_PRIORITY_GWEI  = 1
DEFAULT_MAX_FEE_GWEI   = 50
DEFAULT_GAS_LIMIT      = 250_000   # ~the cost of one ERC-20 transfer with data


@dataclass
class UnsignedMonadTx:
    """An EIP-1559 dynamic-fee transaction ready for wallet signing.

    Field names match what `eth_signTransaction` / `web3.py` expect, so
    a wallet can sign this dict directly.
    """
    chainId: int
    type: int           # 2 = EIP-1559
    nonce: int          # account nonce; caller fills from the chain
    maxFeePerGas: int
    maxPriorityFeePerGas: int
    gas: int
    to: str             # hex address
    value: int          # wei
    data: str           # 0x-prefixed hex
    accessList: list[Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "chainId":              self.chainId,
            "type":                 self.type,
            "nonce":                self.nonce,
            "maxFeePerGas":         self.maxFeePerGas,
            "maxPriorityFeePerGas": self.maxPriorityFeePerGas,
            "gas":                  self.gas,
            "to":                   self.to,
            "value":                self.value,
            "data":                 self.data,
            "accessList":           self.accessList,
        }


def encode_order_calldata(signed: SignedOrder,
    *,
    trusted: TrustedKeys | None = None,
    require_hedged: bool = True,
) -> str:
    """Pack a signed order into a single 0x-hex calldata blob.

    Fail-closed: verifies the embedded PQ signature before serialising.
    Raises `UnverifiableOrder` if verify fails — preventing tampered
    or corrupted artefacts from producing on-chain calldata.

    Layout (length-prefixed bytes triples):
      4-byte magic        b'PQO1' (literal ASCII; v1 format)
      2-byte order_len    big-endian uint16
      <order_len> bytes   canonical JSON of order.to_dict()
      2-byte sig_len      big-endian uint16
      <sig_len> bytes     raw ML-DSA-65 signature
      2-byte pk_len       big-endian uint16
      <pk_len> bytes      raw ML-DSA-65 public key

    The reverse parser lives in decode_order_calldata().
    """
    _verify_or_raise(signed, trusted=trusted, require_hedged=require_hedged)
    # Use the SAME canonicalisation as pq_signing.canonical_bytes (H5):
    # signature verification depends on byte-identical canonical form, so
    # a Solidity / non-Python verifier that hashes the on-chain calldata
    # must see exactly what was signed. The previous `json.dumps` default
    # (ensure_ascii=True) would have desynced on non-ASCII pool labels.
    order_bytes = pq.canonical_bytes(signed.order.to_dict())
    sig_bytes = base64.b64decode(signed.signature_b64)
    pk_bytes  = base64.b64decode(signed.public_key_b64)

    if len(order_bytes) > 0xFFFF:
        raise ValueError("order JSON too long for v1 calldata layout")
    if len(sig_bytes)   > 0xFFFF: raise ValueError("signature too long")
    if len(pk_bytes)    > 0xFFFF: raise ValueError("public key too long")

    parts = [
        b"PQO1",
        len(order_bytes).to_bytes(2, "big"), order_bytes,
        len(sig_bytes).to_bytes(2, "big"),   sig_bytes,
        len(pk_bytes).to_bytes(2, "big"),    pk_bytes,
    ]
    return "0x" + b"".join(parts).hex()


def decode_order_calldata(hex_data: str) -> tuple[dict[str, Any], bytes, bytes]:
    """Round-trip parser. Returns (order_dict, sig_bytes, pk_bytes).

    Raises ValueError on any framing mismatch.
    """
    raw = bytes.fromhex(hex_data.removeprefix("0x"))
    if raw[:4] != b"PQO1":
        raise ValueError(f"bad magic: {raw[:4]!r}")
    pos = 4

    def read_lp() -> bytes:
        nonlocal pos
        n = int.from_bytes(raw[pos:pos + 2], "big")
        pos += 2
        chunk = raw[pos:pos + n]
        if len(chunk) != n:
            raise ValueError("truncated calldata")
        pos += n
        return chunk

    order = json.loads(read_lp().decode("utf-8"))
    sig   = read_lp()
    pk    = read_lp()
    if pos != len(raw):
        raise ValueError(f"trailing bytes after pk: {len(raw) - pos}")
    return order, sig, pk


# --- MonadAllocationVault integration -----------------------------------
#
# MonadAllocationVault.sol (contracts/src/MonadAllocationVault.sol) lets the
# user broadcast a real on-chain effect that references the agent's
# PQ-signed RebalanceOrder: the user deposits native MON into the vault
# under the order's SHA-256, the vault records per-user / per-order
# balance, and emits an `Allocated` event linking the agent's decision
# to a concrete on-chain action. Withdrawals are gated to msg.sender's
# own deposit.
#
# Selectors verified with `forge inspect MonadAllocationVault methods`.
ALLOC_EXECUTE_SELECTOR = bytes.fromhex("4a987805")  # execute(bytes32,bytes32[],uint16[])
ALLOC_EXECUTE_GAS_LIMIT = 130_000                     # measured ~88K on testnet (3-pool), +47% headroom


def encode_alloc_calldata(order_hash: bytes,
                           pool_hashes: list[bytes],
                           weights_bps: list[int]) -> str:
    """Pack a MonadAllocationVault.execute(bytes32,bytes32[],uint16[]) call.

    `pool_hashes` are 32-byte labels (typically keccak256 of the pool
    name string from the agent's off-chain RebalanceOrder). Length must
    match weights_bps; weights_bps must sum to 10_000.
    """
    if len(order_hash) != 32:
        raise ValueError(f"order_hash must be 32 bytes, got {len(order_hash)}")
    if len(pool_hashes) != len(weights_bps):
        raise ValueError(
            f"length mismatch: {len(pool_hashes)} pools vs {len(weights_bps)} weights"
        )
    if not all(len(p) == 32 for p in pool_hashes):
        raise ValueError("each pool_hash must be 32 bytes")
    if sum(weights_bps) != 10_000:
        raise ValueError(f"weights must sum to 10000 bps, got {sum(weights_bps)}")
    if any(w < 0 or w > 0xFFFF for w in weights_bps):
        raise ValueError("each weight must fit in uint16")

    n = len(pool_hashes)
    # ABI layout for execute(bytes32, bytes32[], uint16[]):
    #   word 0:        orderHash (bytes32)
    #   word 1:        offset to pools array (= 0x60)
    #   word 2:        offset to weights array (= 0x60 + 32 + 32*n)
    #   ---- pools array ----
    #   word P0:       length
    #   words P1..Pn:  pool hashes
    #   ---- weights array ----
    #   word W0:       length
    #   words W1..Wn:  each weight as a 32-byte left-padded uint16
    head = b""
    head += order_hash
    pools_offset  = 0x60
    weights_offset = pools_offset + 0x20 + 0x20 * n
    head += pools_offset.to_bytes(32, "big")
    head += weights_offset.to_bytes(32, "big")
    body = n.to_bytes(32, "big")
    for p in pool_hashes:
        body += p
    body += n.to_bytes(32, "big")
    for w in weights_bps:
        body += w.to_bytes(32, "big")
    return "0x" + (ALLOC_EXECUTE_SELECTOR + head + body).hex()


def _keccak256(data: bytes) -> bytes:
    """Ethereum's keccak256 (not NIST SHA-3-256 — different paddings).
    Backed by pycryptodome's Crypto.Hash.keccak, pinned in requirements.txt.
    Used for pool-label hashes and ABI function selectors that must match
    Solidity's `keccak256(...)` byte-for-byte."""
    from Crypto.Hash import keccak as _kk
    h = _kk.new(digest_bits=256)
    h.update(data)
    return h.digest()


def pool_label_hash(label: str) -> bytes:
    """keccak256(label.utf8) — used to encode RebalanceOrder.pools[i]
    into the bytes32 the vault expects. The off-chain order keeps the
    human-readable label; the on-chain log keeps the deterministic
    32-byte identifier so a reviewer can recover the label by
    pre-imaging from the shipped signed_orders.json."""
    return _keccak256(label.encode("utf-8"))


def fractional_weights_to_bps(weights: list[float]) -> list[int]:
    """Convert agent's fractional weights (sum=1.0) to uint16 basis points
    that sum to exactly 10_000. We allocate floor(w * 10000) to each pool
    and give the rounding remainder to the largest-weight pool so the
    sum constraint holds without breaking proportionality much.

    Rejects degenerate inputs: empty list, negative weights, or all-zero
    weights would otherwise silently produce "100% to pool 0" which
    misrepresents the agent's intent on-chain.
    """
    if not weights:
        return []
    if any(w < 0 for w in weights):
        raise ValueError(f"negative weights not allowed: {weights}")
    s = sum(weights)
    if s <= 0:
        raise ValueError(
            "weights sum to 0 — would silently inflate first pool to 100% "
            "and misrepresent the agent's allocation. Refusing to encode."
        )
    # NORMALISE by the actual sum. Previously `s` was computed and used only
    # for the `s <= 0` guard, so the values were scaled as if they already
    # summed to 1.0. They frequently do not, and the remainder-to-largest
    # fixup below then forced sum == 10_000, hiding the error from every
    # downstream guard including the on-chain WeightsDoNotSumTo10000 check.
    # An honest 50/50 order given as [1.0, 1.0] encoded as [0, 10000] — the
    # whole deposit into one pool, and a ZERO-WEIGHT LEG, which the vault
    # used to hand to SwapRouter02 as its CONTRACT_BALANCE sentinel.
    # (Audit: weights normalisation + contract M-5.)
    raw = [int(w / s * 10_000) for w in weights]
    remainder = 10_000 - sum(raw)
    if remainder != 0:
        idx = max(range(len(raw)), key=lambda i: weights[i])
        raw[idx] += remainder
    if sum(raw) != 10_000:
        raise ValueError(f"failed to round to 10000 bps: {raw} sum={sum(raw)}")
    return raw


def build_alloc_tx(
    signed: SignedOrder,
    *,
    vault_contract: str,
    nonce: int,
    amount_wei: int,
    gas_limit: int = ALLOC_EXECUTE_GAS_LIMIT,
    max_fee_gwei: int = DEFAULT_MAX_FEE_GWEI,
    priority_gwei: int = DEFAULT_PRIORITY_GWEI,
    chain_id: int = MONAD_CHAIN_ID,
    trusted: TrustedKeys | None = None,
    require_hedged: bool = True,
) -> UnsignedMonadTx:
    """Build an unsigned EIP-1559 TX that deposits `amount_wei` of native
    MON into the MonadAllocationVault under the agent's signed-order hash.

    The vault enforces:
      * orderHash != 0
      * pools.length == weights.length
      * sum(weightsBps) == 10000

    On success the vault credits the deposit to msg.sender's slot keyed
    by orderHash and emits `Allocated(user, orderHash, amount, pools,
    weights)`. The user can later call `withdraw(orderHash, amount)` to
    pull their MON back.
    """
    _require_address(vault_contract, "vault_contract")
    if amount_wei <= 0:
        raise ValueError(f"amount_wei must be positive, got {amount_wei}")
    _verify_or_raise(signed, trusted=trusted, require_hedged=require_hedged)

    order_hash  = order_sha256(signed)
    pool_hashes = [pool_label_hash(p) for p in signed.order.pools]
    weights_bps = fractional_weights_to_bps(signed.order.weights)

    return UnsignedMonadTx(
        chainId=chain_id,
        type=2,
        nonce=nonce,
        maxFeePerGas=max_fee_gwei * 10 ** 9,
        maxPriorityFeePerGas=priority_gwei * 10 ** 9,
        gas=gas_limit,
        to=vault_contract,
        value=amount_wei,
        data=encode_alloc_calldata(order_hash, pool_hashes, weights_bps),
        accessList=[],
    )


# --- UniswapRoutingVault integration -------------------------------------
#
# UniswapRoutingVault.sol (contracts/src/UniswapRoutingVault.sol) is the
# real-DEX successor to the MiniAMM-era RoutingVault: it wraps the user's
# native MON and swaps each weighted slice into a DeFi token through the
# production Uniswap v3 SwapRouter02 on Monad mainnet
# (0xfE31F71C1b106EAc32F1A19239c9a9A72ddfb900, chainId 143). The caller
# must have most-recently anchored `orderHash` on AuditAnchor, tying the
# on-chain swap back to the off-chain QPU result + PQ signature.
#
# Selector verified with `cast sig` / `forge inspect UniswapRoutingVault
# methods` — regenerate after any signature-changing edit.
ROUTE_EXECUTE_SELECTOR = bytes.fromhex("5caf7a40")
# executeAndRoute(bytes32,address[],uint24[],uint16[],uint256[],uint256)
ROUTE_EXECUTE_GAS_LIMIT = 400_000   # wrap + N exactInputSingle hops; +headroom


def encode_route_calldata(
    order_hash: bytes,
    token_outs: list[str],
    fee_tiers: list[int],
    weights_bps: list[int],
    amount_out_min: list[int],
    deadline: int,
) -> str:
    """Pack a UniswapRoutingVault.executeAndRoute(...) call.

    ABI: executeAndRoute(bytes32 orderHash, address[] tokenOuts,
                         uint24[] feeTiers, uint16[] weightsBps,
                         uint256[] amountOutMin, uint256 deadline)

    All four arrays are parallel (same length n). `token_outs` are
    0x-prefixed 20-byte addresses; `fee_tiers` are Uniswap v3 tiers
    (500/3000/10000); `weights_bps` must sum to 10_000; `amount_out_min`
    are per-hop slippage floors in the output token's smallest unit;
    `deadline` is a unix-seconds timestamp.

    Hand-rolled to match the codebase's zero-web3 encoding style; pinned
    against a `cast calldata` golden in tests/test_monad_tx.py.
    """
    if len(order_hash) != 32:
        raise ValueError(f"order_hash must be 32 bytes, got {len(order_hash)}")
    n = len(token_outs)
    if not (n == len(fee_tiers) == len(weights_bps) == len(amount_out_min)):
        raise ValueError(
            f"array length mismatch: tokenOuts={n} feeTiers={len(fee_tiers)} "
            f"weights={len(weights_bps)} amountOutMin={len(amount_out_min)}"
        )
    if n == 0:
        raise ValueError("at least one pool required")
    if sum(weights_bps) != 10_000:
        raise ValueError(f"weights must sum to 10000 bps, got {sum(weights_bps)}")
    if any(w < 0 or w > 0xFFFF for w in weights_bps):
        raise ValueError("each weight must fit in uint16")
    if any(f < 0 or f > 0xFFFFFF for f in fee_tiers):
        raise ValueError("each fee tier must fit in uint24")
    if any(a < 0 or a >= 2 ** 256 for a in amount_out_min):
        raise ValueError("amountOutMin must fit in uint256")
    if deadline < 0 or deadline >= 2 ** 256:
        raise ValueError("deadline must fit in uint256")

    def addr_word(a: str) -> bytes:
        # Validate the DECODED length, not the string length. `bytes.fromhex`
        # skips ASCII whitespace, so a 42-char string containing spaces
        # decoded to 19 bytes and shifted every subsequent ABI word — the
        # array length prefixes then read as 256 and the calldata was garbage.
        _require_address(a, "tokenOut")
        return bytes(12) + bytes.fromhex(a[2:])

    def uint_array(vals: list[int]) -> bytes:
        out = len(vals).to_bytes(32, "big")
        for v in vals:
            out += v.to_bytes(32, "big")
        return out

    def addr_array(addrs: list[str]) -> bytes:
        out = len(addrs).to_bytes(32, "big")
        for a in addrs:
            out += addr_word(a)
        return out

    # Head: 6 static words (orderHash, 4 array offsets, deadline).
    head_words = 6
    base = head_words * 0x20                     # 0xC0
    stride = 0x20 * (1 + n)                       # length word + n elements
    off_tokens  = base
    off_fees    = off_tokens + stride
    off_weights = off_fees + stride
    off_minouts = off_weights + stride

    head = (
        order_hash
        + off_tokens.to_bytes(32, "big")
        + off_fees.to_bytes(32, "big")
        + off_weights.to_bytes(32, "big")
        + off_minouts.to_bytes(32, "big")
        + deadline.to_bytes(32, "big")
    )
    body = (
        addr_array(token_outs)
        + uint_array(fee_tiers)
        + uint_array(weights_bps)
        + uint_array(amount_out_min)
    )
    return "0x" + (ROUTE_EXECUTE_SELECTOR + head + body).hex()


def build_route_tx(
    signed: SignedOrder,
    *,
    vault_contract: str,
    nonce: int,
    amount_wei: int,
    token_outs: list[str],
    fee_tiers: list[int],
    amount_out_min: list[int],
    deadline: int,
    gas_limit: int = ROUTE_EXECUTE_GAS_LIMIT,
    max_fee_gwei: int = DEFAULT_MAX_FEE_GWEI,
    priority_gwei: int = DEFAULT_PRIORITY_GWEI,
    chain_id: int = MONAD_CHAIN_ID,
    trusted: TrustedKeys | None = None,
    require_hedged: bool = True,
) -> UnsignedMonadTx:
    """Build an unsigned EIP-1559 TX that routes `amount_wei` of native MON
    through the UniswapRoutingVault into `token_outs` on Uniswap v3.

    Weights are derived from the signed order (`signed.order.weights`) so
    the on-chain allocation matches the agent's PQ-signed intent exactly.
    The caller supplies the concrete `token_outs` (the mainnet ERC20 each
    off-chain pool label maps to), `fee_tiers`, per-hop `amount_out_min`
    (slippage floors the agent computes from a QuoterV2 read), and a
    `deadline`. The order's SHA-256 must already be the caller's most
    recent AuditAnchor entry or the vault reverts with AnchorNotFound.
    """
    _require_address(vault_contract, "vault_contract")
    if amount_wei <= 0:
        raise ValueError(f"amount_wei must be positive, got {amount_wei}")
    _verify_or_raise(signed, trusted=trusted, require_hedged=require_hedged)

    order_hash  = order_sha256(signed)
    weights_bps = fractional_weights_to_bps(signed.order.weights)
    if not (len(token_outs) == len(fee_tiers) == len(amount_out_min) == len(weights_bps)):
        raise ValueError(
            "token_outs / fee_tiers / amount_out_min must be parallel to the "
            f"order's {len(weights_bps)} weighted pools"
        )

    return UnsignedMonadTx(
        chainId=chain_id,
        type=2,
        nonce=nonce,
        maxFeePerGas=max_fee_gwei * 10 ** 9,
        maxPriorityFeePerGas=priority_gwei * 10 ** 9,
        gas=gas_limit,
        to=vault_contract,
        value=amount_wei,
        data=encode_route_calldata(
            order_hash, token_outs, fee_tiers, weights_bps, amount_out_min, deadline
        ),
        accessList=[],
    )


# --- AuditAnchor contract integration ------------------------------------
#
# AuditAnchor.sol (contracts/src/AuditAnchor.sol) anchors the SHA-256 of a
# signed order on-chain. We do not verify ML-DSA on-chain (~500 M gas);
# instead we emit a 32-byte digest in an event (~30 K gas per anchor).
#
# Selectors were verified with `forge inspect AuditAnchor methods` —
# regenerate after any signature-changing edit to the contract.
ANCHOR_SELECTOR_NO_SEQ = bytes.fromhex("eecdf927")   # anchor(bytes32)
ANCHOR_SELECTOR_W_SEQ  = bytes.fromhex("db2c4aca")   # anchor(bytes32,uint64)
ANCHOR_GAS_LIMIT       = 60_000                       # cold first call; ~30K steady


def order_sha256(signed: SignedOrder) -> bytes:
    """SHA-256 of the canonical signed-order bytes. This is the 32-byte
    digest the agent anchors on-chain via AuditAnchor.anchor()."""
    import hashlib
    return hashlib.sha256(pq.canonical_bytes(signed.order.to_dict())).digest()


def encode_anchor_calldata(order_hash: bytes,
                            expected_sequence: int | None = None) -> str:
    """Pack an AuditAnchor.anchor(...) call into 0x-prefixed hex calldata.

    Two forms:
      * expected_sequence=None → anchor(bytes32) — convenience overload
      * expected_sequence given → anchor(bytes32, uint64) — race-safe form,
        reverts on-chain if the contract's nextSequence disagrees.
    """
    if len(order_hash) != 32:
        raise ValueError(f"order_hash must be 32 bytes, got {len(order_hash)}")
    if expected_sequence is None:
        return "0x" + (ANCHOR_SELECTOR_NO_SEQ + order_hash).hex()
    if expected_sequence < 0 or expected_sequence >= 2 ** 64:
        raise ValueError("expected_sequence must fit in uint64")
    # ABI-encode uint64 as a 32-byte left-padded big-endian word.
    seq_word = expected_sequence.to_bytes(32, "big")
    return "0x" + (ANCHOR_SELECTOR_W_SEQ + order_hash + seq_word).hex()


def build_anchor_tx(
    signed: SignedOrder,
    *,
    anchor_contract: str,
    nonce: int,
    expected_sequence: int | None = None,
    gas_limit: int = ANCHOR_GAS_LIMIT,
    max_fee_gwei: int = DEFAULT_MAX_FEE_GWEI,
    priority_gwei: int = DEFAULT_PRIORITY_GWEI,
    chain_id: int = MONAD_CHAIN_ID,
    trusted: TrustedKeys | None = None,
    require_hedged: bool = True,
) -> UnsignedMonadTx:
    """Produce an unsigned Monad TX that anchors `signed`'s SHA-256 on-chain.

    The agent's ECDSA wallet signs and broadcasts; the contract emits an
    `Anchored(address, bytes32, uint64, bytes32)` event linking the hash
    to a block height. Reviewers reconstruct the agent's on-chain audit
    chain by filtering this event by the agent's address.
    """
    _require_address(anchor_contract, "anchor_contract")
    _verify_or_raise(signed, trusted=trusted, require_hedged=require_hedged)
    order_hash = order_sha256(signed)
    return UnsignedMonadTx(
        chainId=chain_id,
        type=2,
        nonce=nonce,
        maxFeePerGas=max_fee_gwei * 10 ** 9,
        maxPriorityFeePerGas=priority_gwei * 10 ** 9,
        gas=gas_limit,
        to=anchor_contract,
        value=0,
        data=encode_anchor_calldata(order_hash, expected_sequence),
        accessList=[],
    )


def build_unsigned_tx(
    signed: SignedOrder,
    *,
    to_address: str,
    nonce: int,
    gas_limit: int = DEFAULT_GAS_LIMIT,
    max_fee_gwei: int = DEFAULT_MAX_FEE_GWEI,
    priority_gwei: int = DEFAULT_PRIORITY_GWEI,
    value_wei: int = 0,
    chain_id: int = MONAD_CHAIN_ID,
    trusted: TrustedKeys | None = None,
    require_hedged: bool = True,
) -> UnsignedMonadTx:
    """Produce an unsigned EIP-1559 TX carrying the signed order.

    Caller supplies the destination address (a deployed vault contract,
    or the agent's own address for a self-transfer-with-payload) and the
    current account nonce. A wallet finalises the ECDSA signature.
    """
    _require_address(to_address, "to_address")
    return UnsignedMonadTx(
        chainId=chain_id,
        type=2,
        nonce=nonce,
        maxFeePerGas=max_fee_gwei * 10 ** 9,
        maxPriorityFeePerGas=priority_gwei * 10 ** 9,
        gas=gas_limit,
        to=to_address,
        value=value_wei,
        data=encode_order_calldata(
            signed, trusted=trusted, require_hedged=require_hedged
        ),
        accessList=[],
    )


# --- AuditAnchorV2 execution commitments --------------------------------
#
# These MUST reproduce the Solidity helpers byte-for-byte:
#   UniswapRoutingVault.routeCommitment(address,address[],uint24[],uint16[],
#                                       uint256,uint256[],uint256)
#   MorphoSupplyAdapter.supplyCommitment(address,MarketParams,uint256)
#
# `abi.encode` semantics, never `encodePacked`: packed encoding drops array
# length prefixes, which makes distinct orders collide. With this 7-field
# preimage a single element can migrate across two boundaries at once —
# w=[3000,7000] amountIn=1e18 min=[1,2] packs identically to w=[3000]
# amountIn=7000 min=[1e18,1,2], i.e. the same authorisation for a different
# trade. Verified against `cast abi-encode` and the contract itself.


def _word(v: int) -> bytes:
    if v < 0 or v >= 2 ** 256:
        raise ValueError(f"value does not fit in uint256: {v}")
    return v.to_bytes(32, "big")


def _addr_word(a: str) -> bytes:
    _require_address(a, "address")
    return bytes(12) + bytes.fromhex(a[2:])


def _dyn_uint_array(vals: list[int]) -> bytes:
    return _word(len(vals)) + b"".join(_word(v) for v in vals)


def _dyn_addr_array(vals: list[str]) -> bytes:
    return _word(len(vals)) + b"".join(_addr_word(a) for a in vals)


def route_commitment(ex: RouteExecution) -> bytes:
    """keccak256 of the ABI encoding UniswapRoutingVault.routeCommitment builds.

    A FAITHFUL MIRROR of the Solidity helper, deliberately including its
    permissiveness: the on-chain function is a pure hash and does not require
    the four arrays to be the same length (`executeAndRoute` rejects that
    separately with LengthMismatch). Adding a stricter check here would make
    the two implementations disagree about which inputs are even hashable,
    which is precisely the class of divergence this function must not have.

    Call `validate_route_execution` before anchoring — an unexecutable
    commitment cannot be corrected once anchored (contract L-3).
    """
    tails = [
        _dyn_addr_array(ex.token_outs),
        _dyn_uint_array(ex.fee_tiers),
        _dyn_uint_array(ex.weights_bps),
        _dyn_uint_array(ex.amount_out_min),
    ]
    head_size = 7 * 32
    offs, running = [], head_size
    for t in tails:
        offs.append(running)
        running += len(t)

    head = (
        _addr_word(ex.user)
        + _word(offs[0])
        + _word(offs[1])
        + _word(offs[2])
        + _word(ex.amount_in_wei)
        + _word(offs[3])
        + _word(ex.deadline)
    )
    return _keccak256(head + b"".join(tails))


def validate_route_execution(ex: RouteExecution) -> None:
    """Reject an execution that could never run, BEFORE its commitment is
    anchored. AuditAnchorV2 refuses to re-anchor an orderHash, so anchoring a
    commitment that `executeAndRoute` would reject bricks that order
    permanently — the only recovery is re-signing off-chain."""
    n = len(ex.token_outs)
    if n == 0 or not (n == len(ex.fee_tiers) == len(ex.weights_bps)
                      == len(ex.amount_out_min)):
        raise ValueError(
            "token_outs / fee_tiers / weights_bps / amount_out_min must be "
            f"non-empty and the same length (got {n}, {len(ex.fee_tiers)}, "
            f"{len(ex.weights_bps)}, {len(ex.amount_out_min)})"
        )
    if any(f < 0 or f > 0xFFFFFF for f in ex.fee_tiers):
        raise ValueError("each fee tier must fit in uint24")
    if any(w < 0 or w > 0xFFFF for w in ex.weights_bps):
        raise ValueError("each weight must fit in uint16")
    if sum(ex.weights_bps) != 10_000:
        raise ValueError(f"weights_bps must sum to 10000, got {sum(ex.weights_bps)}")
    if any(w == 0 for w in ex.weights_bps):
        raise ValueError(
            "zero-weight leg: SwapRouter02 reads amountIn == 0 as its "
            "CONTRACT_BALANCE sentinel, and the vault rejects it"
        )
    if any(a == 0 for a in ex.amount_out_min):
        raise ValueError("amountOutMin of 0 is a fail-open slippage floor")
    if ex.amount_in_wei == 0:
        raise ValueError("amount_in_wei must be non-zero")


def supply_commitment(ex: SupplyExecution) -> bytes:
    """keccak256 of the ABI encoding MorphoSupplyAdapter.supplyCommitment builds.

    MarketParams is a 5-field all-static struct, so it inlines as five words
    with no offset — the same reason Morpho's own market id is
    keccak256(abi.encode(params)).
    """
    return _keccak256(
        _addr_word(ex.user)
        + _addr_word(ex.loan_token)
        + _addr_word(ex.collateral_token)
        + _addr_word(ex.oracle)
        + _addr_word(ex.irm)
        + _word(ex.lltv)
        + _word(ex.max_assets)
    )
