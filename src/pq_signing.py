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

def canonical_bytes(obj: Any) -> bytes:
    """Deterministic JSON encoding so signatures verify across machines.

    Uses sorted keys + compact separators. This is a stable subset of
    RFC 8785 JCS — sufficient for an internal protocol where every party
    uses this exact function.
    """
    return json.dumps(obj, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, default=str).encode("utf-8")


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
    """Verify a payload signature. Returns False on any failure."""
    if len(pk) != PUBLIC_KEY_BYTES:
        return False
    try:
        return bool(ML_DSA_65.verify(pk, canonical_bytes(payload), signature))
    except Exception:
        return False
