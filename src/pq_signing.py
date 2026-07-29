"""Hedged signatures for rebalance orders: ML-DSA + SLH-DSA + Ed25519.

Each order is signed by three independent schemes with disjoint security
assumptions. An attacker must break ALL THREE to forge an order:

  * **ML-DSA-65** (NIST FIPS 204) — Module-Lattice. Lattice-based PQ,
    AES-192-equivalent classical security level. Primary PQ signature.
  * **SLH-DSA-SHAKE-256s** (NIST FIPS 205) — hash-based PQ, Level-5
    parameter set (matches AES-256-equivalent classical security).
    Depends only on SHA-3/SHAKE collision resistance — strictly weaker
    assumption than lattices. Hedges against lattice cryptanalytic
    breakthroughs.
  * **Ed25519** (RFC 8032) — classical EdDSA on Curve25519. Included so
    the legacy chain of trust (no PQ tooling) can verify the order today;
    breaks on Q-Day but survives any classical or lattice-only attack.

Standard hybrid-PQ hedge construction (one lattice + one hash-based +
one classical with disjoint security assumptions), implemented
directly against `quantcrypt` and `cryptography` to control dependency
risk.

Backend: `quantcrypt` 1.0.x (PQClean precompiled binaries via Python bindings).
PQClean is the reference C implementation used by liboqs and other PQ
projects; quantcrypt ships precompiled binaries so no C toolchain is
required at install time. Same byte-level FIPS 204 spec as `dilithium-py`
(pk=1952, sk=4032, sig≤3309) — keys generated under either implementation
are interoperable at the spec level.

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
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from quantcrypt.dss import MLDSA_65, SMALL_SPHINCS, DSSVerifyFailedError
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric import ed25519 as _ed25519
from cryptography.hazmat.primitives.serialization import (
    Encoding, NoEncryption, PrivateFormat, PublicFormat,
)

_mldsa = MLDSA_65()
_slhdsa = SMALL_SPHINCS()

# Algorithm metadata exposed for the UI.
ALGORITHM = "ML-DSA-65 (NIST FIPS 204)"
PUBLIC_KEY_BYTES = 1952
SECRET_KEY_BYTES = 4032
SIGNATURE_BYTES_MAX = 3309   # FIPS 204 max; actual sigs may be shorter

# SLH-DSA-SHAKE-256s — NIST FIPS 205 hash-based signature, Level-5
# parameter set (256-bit classical security, AES-256-equivalent). Used
# as a hedge alongside ML-DSA: if a lattice break ever appears against
# ML-DSA, SLH-DSA still holds under the strictly weaker assumption that
# SHA-3/SHAKE remains collision-resistant. Trade-off: large signatures
# (~29 KB) and slow signing (~50–500 ms), acceptable for one rebalance
# per hour. FIPS 205 parameter table for SHAKE-256s: pk=64, sk=128,
# sig=29792. quantcrypt's `SMALL_SPHINCS` maps to PQClean's
# `sphincs-shake-256s-simple` — verified empirically by sizes.
SLH_DSA_ALGORITHM = "SLH-DSA-SHAKE-256s (NIST FIPS 205)"
SLH_DSA_PUBLIC_KEY_BYTES = 64
SLH_DSA_SECRET_KEY_BYTES = 128
SLH_DSA_SIGNATURE_BYTES = 29792   # FIPS 205 SHAKE-256s fixed signature length


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


def _assert_nfc(obj: Any, _path: str = "") -> None:
    """Reject any string that is not already in Unicode NFC form.

    **Validate, never rewrite.** The previous implementation normalised
    every string *before* hashing. NFC is a many-to-one map, so that made
    `canonical_bytes` non-injective: two different logical orders produced
    identical canonical bytes, identical signatures, and an identical
    anchored `orderHash`. Worse, the asymmetry was exploitable — the signer
    normalised but every consumer did not. `monad_tx.pool_label_hash`
    keccaks the RAW label, so an order signed with pool "\u212aUSDC"
    (KELVIN SIGN) could be rewritten to "KUSDC" after signing: same
    signature, same orderHash, DIFFERENT on-chain pool. The same trick
    laundered `qpu_job_id` and `agent_id`. (Audit Z-1.)

    Normalising also silently merged dict keys that share an NFC form,
    dropping a value: {"\u212aey": "attacker", "Key": "honest"} collapsed
    to {"Key": "honest"}.

    Rejecting instead of rewriting makes the signature bind the order's
    actual bytes. This is a no-op for pure-ASCII payloads — every shipped
    artefact canonicalises to exactly the same bytes as before.
    """
    if isinstance(obj, str):
        if obj != unicodedata.normalize("NFC", obj):
            raise ValueError(
                f"non-NFC string at {_path or '<root>'}: {obj!r}. Order fields must "
                "be supplied already NFC-normalised; canonical_bytes refuses to "
                "rewrite them, because rewriting before hashing lets two different "
                "orders share one signature."
            )
        return
    if isinstance(obj, list):
        for i, x in enumerate(obj):
            _assert_nfc(x, f"{_path}[{i}]")
        return
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(k, str):
                _assert_nfc(k, f"{_path}.{k}")
            _assert_nfc(v, f"{_path}.{k}")
        return


def normalize_for_signing(obj: Any) -> Any:
    """Recursively NFC-normalise a payload BEFORE it becomes an order.

    This is the safe half of the old behaviour, moved to where it belongs:
    call it at order-construction time on untrusted input, so the order is
    NFC by the time anything hashes it. Never call it inside the signing
    path — that is precisely the bug Z-1 describes.
    """
    if isinstance(obj, str):
        return unicodedata.normalize("NFC", obj)
    if isinstance(obj, list):
        return [normalize_for_signing(x) for x in obj]
    if isinstance(obj, dict):
        out: dict[Any, Any] = {}
        for k, v in obj.items():
            nk = unicodedata.normalize("NFC", k) if isinstance(k, str) else k
            if nk in out:
                raise ValueError(
                    f"key collision after NFC normalisation: {k!r} -> {nk!r}. "
                    "Two distinct keys share one normalised form; refusing to "
                    "silently drop a value."
                )
            out[nk] = normalize_for_signing(v)
        return out
    return obj


def canonical_bytes(obj: Any) -> bytes:
    """Deterministic JSON encoding so signatures verify across machines.

    Three hardening rules baked in:
      1. **Reject any non-NFC string** (Unicode malleability hardening).
         Validation, not rewriting — see `_assert_nfc` for why the
         difference is load-bearing.
      2. **Sorted keys + compact separators** (stable subset of RFC 8785 JCS).
      3. **Reject NaN / Infinity** (`allow_nan=False`) — Python's `json`
         emits non-RFC-8259 tokens by default, which strict parsers in
         Go / Rust / browser-side reject. A bad-faith signer could
         otherwise produce a payload that verifies locally but
         silently fails every external verifier.

    Rejects non-JSON-native types via `_strict_default` rather than
    silently coercing them (which would break round-trip).

    No-op for pure-ASCII finite-float payloads — the shipped
    `outputs/signed_orders.json` (and its anchored SHA-256) is
    unchanged by introducing these hardenings; only future malicious
    or accidentally-non-normalised input is now rejected.
    """
    _assert_nfc(obj)
    return json.dumps(obj,
                      sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False,
                      default=_strict_default).encode("utf-8")


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


class MissingKeypair(FileNotFoundError):
    """Raised when a keys directory has no keypair and creation was not
    explicitly requested.

    On 2026-07-12 the mainnet order behind the shipped provenance trail was
    signed by an ML-DSA key that is not the one in `keys/` — SHA-256
    8a1b08d1... versus ac0b2aea... The keys directory is gitignored and
    KEYS_DIR is relative to the working directory, so running the pipeline
    from a fresh clone, a different cwd, or a tree copied without ignored
    files made `ensure_keypair` silently mint a NEW identity and sign as
    somebody else. Nothing warned; the run simply became a different agent,
    and when that host was decommissioned the identity went with it.

    Creating a signing identity is now an explicit act. Pass
    `allow_create=True` exactly once, when you genuinely intend to bring a
    new agent into existence.
    """


def generate_keypair() -> KeyPair:
    pk, sk = _mldsa.keygen()
    return KeyPair(pk=bytes(pk), sk=bytes(sk))


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


def ensure_keypair(path: Path | str, *, allow_create: bool = False) -> KeyPair:
    """Load the keypair from `path`, or generate a new one and persist it
    if no keys are present. Idempotent."""
    path = Path(path)
    if (path / "pq.sec").exists() and (path / "pq.pub").exists():
        return load_keypair(path)
    if not allow_create:
        raise MissingKeypair(
            f"no ML-DSA-65 keypair in {path.resolve()} and allow_create=False. "
            "Refusing to silently generate a NEW signing identity — that is "
            "how the 2026-07-12 mainnet signing key was lost. If you meant to "
            "restore an existing identity, decrypt it with src.keystore; if "
            "you genuinely intend to create a new agent, pass allow_create=True."
        )
    kp = generate_keypair()
    save_keypair(kp, path)
    return kp


# --- sign / verify -------------------------------------------------------

def sign(payload: Any, sk: bytes) -> bytes:
    """Sign the canonical encoding of `payload` with ML-DSA-65."""
    if len(sk) != SECRET_KEY_BYTES:
        raise ValueError(f"sk length {len(sk)} != {SECRET_KEY_BYTES}")
    return bytes(_mldsa.sign(sk, canonical_bytes(payload)))


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
        _mldsa.verify(pk, canonical_bytes(payload), signature)
        return True
    except DSSVerifyFailedError:
        # Legitimate cryptographic failure (tampered payload / wrong key /
        # malformed sig). Distinct from caller-side type errors above.
        return False
    except (ValueError, AssertionError):
        return False


# --- SLH-DSA hedge (hash-based, independent assumption) -----------------

@dataclass(frozen=True)
class SLHDSAKeyPair:
    """SLH-DSA-SHAKE-256s keypair. Treat .sk as a secret."""
    pk: bytes
    sk: bytes


def slh_dsa_generate_keypair() -> SLHDSAKeyPair:
    pk, sk = _slhdsa.keygen()
    return SLHDSAKeyPair(pk=bytes(pk), sk=bytes(sk))


def slh_dsa_save_keypair(kp: SLHDSAKeyPair, path: Path | str) -> None:
    """Persist SLH-DSA keys with strict perms on the secret key (0600)."""
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True)
    pk_path = path / "slh.pub"
    sk_path = path / "slh.sec"
    pk_path.write_bytes(kp.pk)
    sk_path.write_bytes(kp.sk)
    os.chmod(sk_path, stat.S_IRUSR | stat.S_IWUSR)
    os.chmod(pk_path, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)


def slh_dsa_load_keypair(path: Path | str) -> SLHDSAKeyPair:
    path = Path(path)
    pk = (path / "slh.pub").read_bytes()
    sk = (path / "slh.sec").read_bytes()
    if len(pk) != SLH_DSA_PUBLIC_KEY_BYTES:
        raise ValueError(f"corrupt SLH-DSA pk: got {len(pk)} bytes, expected {SLH_DSA_PUBLIC_KEY_BYTES}")
    if len(sk) != SLH_DSA_SECRET_KEY_BYTES:
        raise ValueError(f"corrupt SLH-DSA sk: got {len(sk)} bytes, expected {SLH_DSA_SECRET_KEY_BYTES}")
    return SLHDSAKeyPair(pk=pk, sk=sk)


def slh_dsa_ensure_keypair(path: Path | str, *, allow_create: bool = False) -> SLHDSAKeyPair:
    """Load SLH-DSA keypair from `path`, or generate and persist if absent."""
    path = Path(path)
    if (path / "slh.sec").exists() and (path / "slh.pub").exists():
        return slh_dsa_load_keypair(path)
    if not allow_create:
        raise MissingKeypair(
            f"no SLH-DSA keypair in {path.resolve()} and allow_create=False. "
            "Refusing to silently generate a NEW signing identity — that is "
            "how the 2026-07-12 mainnet signing key was lost. If you meant to "
            "restore an existing identity, decrypt it with src.keystore; if "
            "you genuinely intend to create a new agent, pass allow_create=True."
        )
    kp = slh_dsa_generate_keypair()
    slh_dsa_save_keypair(kp, path)
    return kp


def slh_dsa_sign(payload: Any, sk: bytes) -> bytes:
    """Sign the canonical encoding of `payload` with SLH-DSA-SHAKE-256s."""
    if len(sk) != SLH_DSA_SECRET_KEY_BYTES:
        raise ValueError(f"sk length {len(sk)} != {SLH_DSA_SECRET_KEY_BYTES}")
    return bytes(_slhdsa.sign(sk, canonical_bytes(payload)))


def slh_dsa_verify(payload: Any, signature: bytes, pk: bytes) -> bool:
    """Verify an SLH-DSA signature. Same strict-typing semantics as verify()."""
    if pk is None or signature is None or payload is None:
        raise TypeError("payload, signature, and pk are all required")
    if not isinstance(pk, (bytes, bytearray)) or not isinstance(signature, (bytes, bytearray)):
        raise TypeError("pk and signature must be bytes-like")
    if len(pk) != SLH_DSA_PUBLIC_KEY_BYTES:
        return False
    try:
        _slhdsa.verify(pk, canonical_bytes(payload), signature)
        return True
    except DSSVerifyFailedError:
        return False
    except (ValueError, AssertionError):
        return False


# --- Ed25519 classical leg (the hybrid's pre-Q-Day half) ----------------

ED25519_ALGORITHM = "Ed25519 (RFC 8032)"
ED25519_PUBLIC_KEY_BYTES = 32
ED25519_SECRET_KEY_BYTES = 32
ED25519_SIGNATURE_BYTES = 64


@dataclass(frozen=True)
class Ed25519KeyPair:
    """Ed25519 keypair (raw 32-byte form). Treat .sk as a secret."""
    pk: bytes
    sk: bytes


def ed25519_generate_keypair() -> Ed25519KeyPair:
    sk_obj = _ed25519.Ed25519PrivateKey.generate()
    sk = sk_obj.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    pk = sk_obj.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return Ed25519KeyPair(pk=pk, sk=sk)


def ed25519_save_keypair(kp: Ed25519KeyPair, path: Path | str) -> None:
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True)
    pk_path = path / "ed25519.pub"
    sk_path = path / "ed25519.sec"
    pk_path.write_bytes(kp.pk)
    sk_path.write_bytes(kp.sk)
    os.chmod(sk_path, stat.S_IRUSR | stat.S_IWUSR)
    os.chmod(pk_path, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)


def ed25519_load_keypair(path: Path | str) -> Ed25519KeyPair:
    path = Path(path)
    pk = (path / "ed25519.pub").read_bytes()
    sk = (path / "ed25519.sec").read_bytes()
    if len(pk) != ED25519_PUBLIC_KEY_BYTES:
        raise ValueError(f"corrupt Ed25519 pk: got {len(pk)} bytes, expected {ED25519_PUBLIC_KEY_BYTES}")
    if len(sk) != ED25519_SECRET_KEY_BYTES:
        raise ValueError(f"corrupt Ed25519 sk: got {len(sk)} bytes, expected {ED25519_SECRET_KEY_BYTES}")
    return Ed25519KeyPair(pk=pk, sk=sk)


def ed25519_ensure_keypair(path: Path | str, *, allow_create: bool = False) -> Ed25519KeyPair:
    path = Path(path)
    if (path / "ed25519.sec").exists() and (path / "ed25519.pub").exists():
        return ed25519_load_keypair(path)
    if not allow_create:
        raise MissingKeypair(
            f"no Ed25519 keypair in {path.resolve()} and allow_create=False. "
            "Refusing to silently generate a NEW signing identity — that is "
            "how the 2026-07-12 mainnet signing key was lost. If you meant to "
            "restore an existing identity, decrypt it with src.keystore; if "
            "you genuinely intend to create a new agent, pass allow_create=True."
        )
    kp = ed25519_generate_keypair()
    ed25519_save_keypair(kp, path)
    return kp


def ed25519_sign(payload: Any, sk: bytes) -> bytes:
    if len(sk) != ED25519_SECRET_KEY_BYTES:
        raise ValueError(f"sk length {len(sk)} != {ED25519_SECRET_KEY_BYTES}")
    sk_obj = _ed25519.Ed25519PrivateKey.from_private_bytes(sk)
    return sk_obj.sign(canonical_bytes(payload))


def ed25519_verify(payload: Any, signature: bytes, pk: bytes) -> bool:
    if pk is None or signature is None or payload is None:
        raise TypeError("payload, signature, and pk are all required")
    if not isinstance(pk, (bytes, bytearray)) or not isinstance(signature, (bytes, bytearray)):
        raise TypeError("pk and signature must be bytes-like")
    if len(pk) != ED25519_PUBLIC_KEY_BYTES:
        return False
    try:
        pk_obj = _ed25519.Ed25519PublicKey.from_public_bytes(pk)
        pk_obj.verify(signature, canonical_bytes(payload))
        return True
    except InvalidSignature:
        return False
    except (ValueError, TypeError):
        return False
