"""Construct an unsigned Monad rebalance transaction from a signed order.

Turns a PQ-signed `SignedOrder` into a wallet-ready unsigned EIP-1559
transaction. The `data` field carries the order + post-quantum signature
+ public key, so the on-chain audit record links to the off-chain QPU
result.

Two intended modes:

  1. Self-transfer-with-payload — the agent sends 0 MON to itself with
     the signed order encoded in calldata. Simplest possible Monad
     artefact that proves the pipeline produces a valid transaction.

  2. Vault call — calls an on-chain contract like
     `AgentVault.executeRebalance(bytes order, bytes sig, bytes pk)`.
     The function selector is computed via keccak256 (here we just
     leave a placeholder; wiring to a real deployed contract is the
     next step beyond this MVP).

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

from .orders import SignedOrder

# Monad mainnet chain id (verify at https://docs.monad.xyz)
MONAD_CHAIN_ID = 143

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
    order_bytes = json.dumps(signed.order.to_dict(), sort_keys=True,
                             separators=(",", ":")).encode("utf-8")
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
