"""Post-quantum signatures for rebalance orders.

Uses ML-DSA-65 (NIST FIPS 204), the standardised signature scheme based on
the Module-Lattice problem. ML-DSA-65 is the canonical security level for
general-purpose applications — equivalent to roughly AES-192 against
classical and quantum attackers.

Why this matters for the project:
  * Today's wallets (Bitcoin, Ethereum, Monad) sign with ECDSA, which a
    Shor-capable QPU breaks in minutes once cryptographically relevant
    quantum computers exist ("Q-Day").
  * Real-world Q-Day risk is "harvest now, decrypt later" — adversaries
    can record signed transactions today and break them once hardware
    matures. PQ signing alongside ECDSA mitigates this.
  * The agent's rebalance ORDER (an instruction off-chain) is what we
    sign here. The on-chain Monad transaction itself still uses ECDSA
    because the chain doesn't support PQ signatures yet; that mismatch
    is documented in SECURITY.md.

Key sizes (FIPS 204 ML-DSA-65):
    public key:  1952 bytes
    secret key:  4032 bytes
    signature:   3309 bytes
"""
from __future__ import annotations

import hashlib
import json
import os
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from dilithium_py.ml_dsa import ML_DSA_65

# Algorithm metadata exposed for the UI.
ALGORITHM = "ML-DSA-65 (NIST FIPS 204)"
PUBLIC_KEY_BYTES = 1952
SECRET_KEY_BYTES = 4032
SIGNATURE_BYTES_MAX = 3309   # FIPS 204 max; actual sigs may be shorter


# --- canonical JSON serialisation ----------------------------------------

_ALLOWED_TYPES = (type(None), bool, int, float, str, list, dict)


def _strict_default(obj: Any) -> Any:
    """Refuse to silently stringify unknown types — fail loudly instead.

    JSON's `default=str` is a footgun: a `datetime` or `Decimal` slipped
    into a payload gets stringified one way and reconstructed another,
    breaking signature verification across versions or platforms. Better
    to crash and force the caller to convert explicitly.
    """
    raise TypeError(
        f"canonical_bytes() refuses to serialise {type(obj).__name__}. "
        "Convert to str/int/float/list/dict explicitly before signing."
    )


def canonical_bytes(obj: Any) -> bytes:
    """Deterministic JSON encoding so signatures verify across machines.

    Uses sorted keys + compact separators. Rejects non-JSON-native types
    rather than silently coercing them (which would break round-trip).
    This is a stable subset of RFC 8785 JCS — sufficient for an internal
    protocol where every party uses this exact function.
    """
    return json.dumps(obj, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, default=_strict_default).encode("utf-8")


def message_digest(obj: Any) -> str:
    """SHA-256 fingerprint of the canonical encoding — for human display
    and quick integrity checks. Not used by ML-DSA (ML-DSA hashes
    internally), but useful for tamper-evidence in logs."""
    return hashlib.sha256(canonical_bytes(obj)).hexdigest()


# --- keypair lifecycle ---------------------------------------------------

@dataclass(frozen=True)
class KeyPair:
    """ML-DSA-65 keypair. Treat .sk as a secret."""
    pk: bytes
    sk: bytes


def generate_keypair() -> KeyPair:
    pk, sk = ML_DSA_65.keygen()
    return KeyPair(pk=pk, sk=sk)


def save_keypair(kp: KeyPair, path: Path | str) -> None:
    """Write keypair to disk with strict permissions (chmod 600 on the
    secret-key file). The public-key file is world-readable."""
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True)
    pk_path = path / "pq.pub"
    sk_path = path / "pq.sec"
    pk_path.write_bytes(kp.pk)
    sk_path.write_bytes(kp.sk)
    os.chmod(sk_path, stat.S_IRUSR | stat.S_IWUSR)         # 600
    os.chmod(pk_path, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)


def load_keypair(path: Path | str) -> KeyPair:
    path = Path(path)
    pk = (path / "pq.pub").read_bytes()
    sk = (path / "pq.sec").read_bytes()
    if len(pk) != PUBLIC_KEY_BYTES:
        raise ValueError(f"corrupt public key: got {len(pk)} bytes, expected {PUBLIC_KEY_BYTES}")
    if len(sk) != SECRET_KEY_BYTES:
        raise ValueError(f"corrupt secret key: got {len(sk)} bytes, expected {SECRET_KEY_BYTES}")
    return KeyPair(pk=pk, sk=sk)


def ensure_keypair(path: Path | str) -> KeyPair:
    """Load the keypair from `path`, or generate a new one and persist it
    if no keys are present. Idempotent."""
    path = Path(path)
    if (path / "pq.sec").exists() and (path / "pq.pub").exists():
        return load_keypair(path)
    kp = generate_keypair()
    save_keypair(kp, path)
    return kp


# --- sign / verify -------------------------------------------------------

def sign(payload: Any, sk: bytes) -> bytes:
    """Sign the canonical encoding of `payload` with ML-DSA-65."""
    if len(sk) != SECRET_KEY_BYTES:
        raise ValueError(f"sk length {len(sk)} != {SECRET_KEY_BYTES}")
    return ML_DSA_65.sign(sk, canonical_bytes(payload))


def verify(payload: Any, signature: bytes, pk: bytes) -> bool:
    """Verify a payload signature.

    Returns False on legitimate verification failure (tampered payload,
    wrong key, malformed signature length). RAISES on programmer errors
    (NoneType, type mismatches) instead of silently returning False — so
    a bug in the caller can't be confused with a malicious signature.
    """
    if pk is None or signature is None or payload is None:
        raise TypeError("payload, signature, and pk are all required")
    if not isinstance(pk, (bytes, bytearray)) or not isinstance(signature, (bytes, bytearray)):
        raise TypeError("pk and signature must be bytes-like")
    if len(pk) != PUBLIC_KEY_BYTES:
        return False
    try:
        return bool(ML_DSA_65.verify(pk, canonical_bytes(payload), signature))
    except (ValueError, AssertionError):
        # Malformed signature bytes / invalid encoding -> legitimate "no".
        return False
