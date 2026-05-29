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

  3. Vault execution (future) — calls a future DEX-router-coupled vault
     such as `AgentVault.executeRebalance(bytes order, bytes sig)`. Not
     wired in this MVP; the trade-execution layer is deferred (see
     "What would happen with funding" in SUBMISSION.md).

The transaction is NOT signed with ECDSA here. A wallet (MetaMask, a
custodian, or web3.py) signs and broadcasts it. That intentional
separation means: the agent's PQ key authorises the INTENT, the
wallet's ECDSA key authorises the EXECUTION. Two-key custody.
"""
from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any

from . import pq_signing as pq
from .orders import SignedOrder

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


def encode_order_calldata(signed: SignedOrder) -> str:
    """Pack a signed order into a single 0x-hex calldata blob.

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
) -> UnsignedMonadTx:
    """Produce an unsigned Monad TX that anchors `signed`'s SHA-256 on-chain.

    The agent's ECDSA wallet signs and broadcasts; the contract emits an
    `Anchored(address, bytes32, uint64, bytes32)` event linking the hash
    to a block height. Reviewers reconstruct the agent's on-chain audit
    chain by filtering this event by the agent's address.
    """
    if not (anchor_contract.startswith("0x") and len(anchor_contract) == 42):
        raise ValueError(f"anchor_contract must be a 0x-prefixed 20-byte hex: {anchor_contract}")
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
) -> UnsignedMonadTx:
    """Produce an unsigned EIP-1559 TX carrying the signed order.

    Caller supplies the destination address (a deployed vault contract,
    or the agent's own address for a self-transfer-with-payload) and the
    current account nonce. A wallet finalises the ECDSA signature.
    """
    if not (to_address.startswith("0x") and len(to_address) == 42):
        raise ValueError(f"to_address must be a 0x-prefixed 20-byte hex: {to_address}")
    return UnsignedMonadTx(
        chainId=chain_id,
        type=2,
        nonce=nonce,
        maxFeePerGas=max_fee_gwei * 10 ** 9,
        maxPriorityFeePerGas=priority_gwei * 10 ** 9,
        gas=gas_limit,
        to=to_address,
        value=value_wei,
        data=encode_order_calldata(signed),
        accessList=[],
    )
