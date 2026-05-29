"""Rebalance-order schema, audit log, replay protection, hash-chain.

An *order* is the off-chain instruction the agent issues before submitting
an on-chain transaction. Every order carries:

    schema_version  — bumped whenever the order layout changes
    order_id        — UUID4
    nonce           — UUID4, tracked in the audit log to block replay
    issued_at       — ISO-8601 UTC timestamp
    agent_id        — identity of the agent that produced the order
    pools, weights, expected_return, expected_vol  — the rebalance itself
    qpu_job_id, qaoa_p_optimal  — verifiable QPU provenance (when present)

Two artefacts are produced for every signed order:
  outputs/signed_orders.json  — list of every order + signature + status
  outputs/audit_log.jsonl     — append-only JSON-lines log; each entry
                                includes prev_hash forming a hash chain,
                                so a deleted middle line breaks the chain
                                and is detectable.

Schema versioning rules:
  * SCHEMA_VERSION is bumped any time RebalanceOrder gains/renames fields
  * orders with a schema_version newer than this code fail to verify
  * orders with an older schema_version still verify (we keep the old
    canonicalisation) — handled in canonical_payload()
"""
from __future__ import annotations

import base64
import datetime as dt
import fcntl
import hashlib
import json
import os
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable

from . import pq_signing as pq

SCHEMA_VERSION    = 1
DEFAULT_AGENT_ID  = "empowertours-quantum-portfolio-v0.1"
SIGNED_ORDERS_PATH = Path("outputs/signed_orders.json")
AUDIT_LOG_PATH     = Path("outputs/audit_log.jsonl")
GENESIS_PREV_HASH  = "0" * 64  # the first entry's prev_hash sentinel


def _utcnow_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


@dataclass
class RebalanceOrder:
    pools: list[str]
    weights: list[float]
    expected_return: float
    expected_vol: float
    qpu_job_id: str | None = None
    qaoa_p_optimal: float | None = None
    agent_id: str = DEFAULT_AGENT_ID
    order_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    nonce: str = field(default_factory=lambda: str(uuid.uuid4()))
    issued_at: str = field(default_factory=_utcnow_iso)
    schema_version: int = SCHEMA_VERSION

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class SignedOrder:
    """A rebalance order with one or three independent signatures.

    Backwards-compat shape: `algorithm`, `public_key_b64`, and `signature_b64`
    always refer to the ML-DSA-65 (FIPS 204) primary signature, so older
    consumers keep working.

    Hedged orders additionally carry SLH-DSA (FIPS 205, hash-based PQ) and
    Ed25519 (RFC 8032, classical) sub-signatures. An attacker must break all
    three to forge a hedged order.
    """
    order: RebalanceOrder
    algorithm: str
    public_key_b64: str
    signature_b64: str
    message_digest_sha256: str
    # Optional hedge fields — None for ML-DSA-only orders.
    slh_dsa_public_key_b64: str | None = None
    slh_dsa_signature_b64: str | None = None
    ed25519_public_key_b64: str | None = None
    ed25519_signature_b64: str | None = None

    @property
    def is_hedged(self) -> bool:
        return all((
            self.slh_dsa_public_key_b64, self.slh_dsa_signature_b64,
            self.ed25519_public_key_b64, self.ed25519_signature_b64,
        ))

    def to_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {
            "order": self.order.to_dict(),
            "algorithm": self.algorithm,
            "public_key_b64": self.public_key_b64,
            "signature_b64": self.signature_b64,
            "message_digest_sha256": self.message_digest_sha256,
        }
        if self.slh_dsa_signature_b64 is not None:
            d["slh_dsa_public_key_b64"] = self.slh_dsa_public_key_b64
            d["slh_dsa_signature_b64"] = self.slh_dsa_signature_b64
        if self.ed25519_signature_b64 is not None:
            d["ed25519_public_key_b64"] = self.ed25519_public_key_b64
            d["ed25519_signature_b64"] = self.ed25519_signature_b64
        return d


# --- replay protection --------------------------------------------------

class NonceSeenError(ValueError):
    """Raised when an order's nonce has already appeared in the audit log."""


def _load_seen_nonces(log_path: Path = AUDIT_LOG_PATH) -> set[str]:
    if not log_path.exists():
        return set()
    seen: set[str] = set()
    with log_path.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                seen.add(entry["order"]["nonce"])
            except Exception:
                continue   # tolerate corrupt lines
    return seen


# --- sign + log ---------------------------------------------------------

def sign_order(order: RebalanceOrder, keypair: pq.KeyPair,
               seen_nonces: set[str] | None = None) -> SignedOrder:
    """Sign an order with ML-DSA-65 and reject already-seen nonces.

    The signature covers the canonical encoding of the order dict — same
    bytes that `pq.canonical_bytes` produces — so any tampered field
    (including pool order or weight precision) invalidates the signature.
    """
    if seen_nonces is None:
        seen_nonces = _load_seen_nonces()
    if order.nonce in seen_nonces:
        raise NonceSeenError(f"nonce already used: {order.nonce}")

    payload = order.to_dict()
    sig = pq.sign(payload, keypair.sk)
    return SignedOrder(
        order=order,
        algorithm=pq.ALGORITHM,
        public_key_b64=base64.b64encode(keypair.pk).decode("ascii"),
        signature_b64=base64.b64encode(sig).decode("ascii"),
        message_digest_sha256=pq.message_digest(payload),
    )


def sign_order_hedged(order: RebalanceOrder,
                      ml_dsa_kp: pq.KeyPair,
                      slh_dsa_kp: pq.SLHDSAKeyPair,
                      ed25519_kp: pq.Ed25519KeyPair,
                      seen_nonces: set[str] | None = None) -> SignedOrder:
    """Triple-sign an order: ML-DSA + SLH-DSA + Ed25519.

    All three signatures cover the same canonical payload bytes. Any
    tampered field invalidates all three. Defence in depth: an attacker
    needs to break the Module-LWE lattice problem, the SHA-3 collision
    resistance, AND the Ed25519 discrete log to forge an order.
    """
    if seen_nonces is None:
        seen_nonces = _load_seen_nonces()
    if order.nonce in seen_nonces:
        raise NonceSeenError(f"nonce already used: {order.nonce}")

    payload = order.to_dict()
    ml_sig  = pq.sign(payload, ml_dsa_kp.sk)
    slh_sig = pq.slh_dsa_sign(payload, slh_dsa_kp.sk)
    ed_sig  = pq.ed25519_sign(payload, ed25519_kp.sk)

    algorithm = (
        f"{pq.ALGORITHM} + {pq.SLH_DSA_ALGORITHM} + {pq.ED25519_ALGORITHM} (hedged)"
    )
    return SignedOrder(
        order=order,
        algorithm=algorithm,
        public_key_b64=base64.b64encode(ml_dsa_kp.pk).decode("ascii"),
        signature_b64=base64.b64encode(ml_sig).decode("ascii"),
        message_digest_sha256=pq.message_digest(payload),
        slh_dsa_public_key_b64=base64.b64encode(slh_dsa_kp.pk).decode("ascii"),
        slh_dsa_signature_b64=base64.b64encode(slh_sig).decode("ascii"),
        ed25519_public_key_b64=base64.b64encode(ed25519_kp.pk).decode("ascii"),
        ed25519_signature_b64=base64.b64encode(ed_sig).decode("ascii"),
    )


def verify_signed_order(signed: SignedOrder) -> bool:
    """Verify every signature attached to the order.

    Always verifies the ML-DSA primary signature. If hedge signatures are
    present (SLH-DSA, Ed25519), verifies those too. Returns True only if
    EVERY present signature verifies — an attacker who breaks one scheme
    still cannot pass this check on a hedged order.
    """
    payload = signed.order.to_dict()
    pk  = base64.b64decode(signed.public_key_b64)
    sig = base64.b64decode(signed.signature_b64)
    if not pq.verify(payload, sig, pk):
        return False
    if signed.slh_dsa_signature_b64 is not None:
        slh_pk  = base64.b64decode(signed.slh_dsa_public_key_b64 or "")
        slh_sig = base64.b64decode(signed.slh_dsa_signature_b64)
        if not pq.slh_dsa_verify(payload, slh_sig, slh_pk):
            return False
    if signed.ed25519_signature_b64 is not None:
        ed_pk  = base64.b64decode(signed.ed25519_public_key_b64 or "")
        ed_sig = base64.b64decode(signed.ed25519_signature_b64)
        if not pq.ed25519_verify(payload, ed_sig, ed_pk):
            return False
    return True


def verify_signed_order_components(signed: SignedOrder) -> dict[str, bool]:
    """Return per-component verification results (for UI / debugging)."""
    payload = signed.order.to_dict()
    out: dict[str, bool] = {}
    out["ml_dsa"] = pq.verify(
        payload,
        base64.b64decode(signed.signature_b64),
        base64.b64decode(signed.public_key_b64),
    )
    if signed.slh_dsa_signature_b64 is not None:
        out["slh_dsa"] = pq.slh_dsa_verify(
            payload,
            base64.b64decode(signed.slh_dsa_signature_b64),
            base64.b64decode(signed.slh_dsa_public_key_b64 or ""),
        )
    if signed.ed25519_signature_b64 is not None:
        out["ed25519"] = pq.ed25519_verify(
            payload,
            base64.b64decode(signed.ed25519_signature_b64),
            base64.b64decode(signed.ed25519_public_key_b64 or ""),
        )
    return out


def _last_line_hash(log_path: Path) -> str:
    """Return SHA-256 of the last non-empty line of the log, or genesis.

    Doubling-window reverse scan: starts with an 8 KB window at EOF and
    doubles until the window contains a complete trailing line (or the
    whole file). Correct regardless of individual line length, where the
    previous fixed 64 KB scan would silently return SHA-256 of a
    truncated fragment for any entry crossing that threshold.

    Always opens its own fresh file descriptor — the caller (including
    `append_audit` while holding `flock`) gets a guaranteed-current view
    of the inode rather than a possibly-stale BufferedRandom state from
    its own open handle.
    """
    if not log_path.exists() or log_path.stat().st_size == 0:
        return GENESIS_PREV_HASH

    file_size = log_path.stat().st_size
    window = 8192
    last_line = b""
    while True:
        start = max(0, file_size - window)
        with log_path.open("rb") as fh:
            fh.seek(start)
            chunk = fh.read(file_size - start)
        # Strip trailing newlines so the file's terminator does not look
        # like a "line break" inside the chunk.
        stripped = chunk.rstrip(b"\r\n")
        if not stripped:
            # File contained only whitespace.
            return GENESIS_PREV_HASH
        last_nl = stripped.rfind(b"\n")
        if last_nl >= 0:
            last_line = stripped[last_nl + 1:]
            break
        # No prior newline in the window — either the trailing line spans
        # past our window's start, or the entire file is one line.
        if start == 0 or window >= file_size:
            last_line = stripped
            break
        window = min(window * 2, file_size)

    if not last_line:
        return GENESIS_PREV_HASH
    return hashlib.sha256(last_line).hexdigest()


class AuditVerifyFailed(ValueError):
    """Raised by append_audit if the signature does not verify.

    A post-sign verify failure is a bug (sign produced an invalid
    signature), not a normal-flow case to silently record. Fail loud.
    """


def append_audit(signed: SignedOrder,
                 log_path: Path = AUDIT_LOG_PATH,
                 verified: bool | None = None) -> None:
    """Append the signed order to the audit log, hash-chained to the
    previous entry. Creates the file if needed.

    Each entry stores `prev_hash` = SHA-256 of the previous line's bytes.
    Deleting or reordering lines invalidates the chain and is detected by
    `verify_audit_chain()`.

    Concurrency (B3): holds an exclusive POSIX advisory lock (`flock`)
    on the log file across the read-prev-hash + write so two concurrent
    callers cannot append entries pointing to the same predecessor. The
    Streamlit "Sign" button is reachable by every browser tab; an
    unlocked race would break the chain irrecoverably.

    Fail-closed (H6): if the signature does not verify, raises
    `AuditVerifyFailed` rather than recording an unverifiable entry.
    """
    log_path.parent.mkdir(parents=True, exist_ok=True)

    ok = bool(verified) if verified is not None else verify_signed_order(signed)
    if not ok:
        raise AuditVerifyFailed(
            f"refusing to append unverifiable order {signed.order.order_id}"
        )

    entry = signed.to_dict()
    entry["verified_at_sign_time"] = True

    # Hold the lock on a write-only append fd; read the prev-hash via a
    # fresh fd inside the locked section so we always see the current
    # on-disk state (Python's BufferedRandom on an already-open fd can
    # return cached metadata from before another writer's flush).
    with log_path.open("ab") as fh:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        try:
            entry["prev_hash"] = _last_line_hash(log_path)
            line = (json.dumps(entry, separators=(",", ":")) + "\n").encode("utf-8")
            fh.write(line)
            fh.flush()
            os.fsync(fh.fileno())  # durability before releasing the lock
        finally:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def verify_audit_chain(log_path: Path = AUDIT_LOG_PATH) -> tuple[bool, int, str]:
    """Walk the audit log and check every prev_hash matches the prior line.

    Returns (ok, n_entries, reason). On success reason is empty.
    """
    if not log_path.exists():
        return True, 0, ""
    prev_hash = GENESIS_PREV_HASH
    n = 0
    with log_path.open("rb") as fh:
        for raw in fh:
            stripped = raw.strip()
            if not stripped:
                continue
            try:
                entry = json.loads(stripped)
            except json.JSONDecodeError as e:
                return False, n, f"line {n + 1}: invalid JSON ({e})"
            got = entry.get("prev_hash")
            if got != prev_hash:
                return False, n, (
                    f"line {n + 1}: prev_hash mismatch "
                    f"(expected {prev_hash[:12]}…, got {(got or 'missing')[:12]}…)"
                )
            prev_hash = hashlib.sha256(stripped).hexdigest()
            n += 1
    return True, n, ""


def save_signed_orders(orders: Iterable[SignedOrder],
                       path: Path = SIGNED_ORDERS_PATH) -> None:
    """Overwrite the signed-orders aggregate file with the given orders."""
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = [s.to_dict() for s in orders]
    path.write_text(json.dumps(payload, indent=2))


def load_signed_orders(path: Path = SIGNED_ORDERS_PATH) -> list[SignedOrder]:
    if not path.exists():
        return []
    raw = json.loads(path.read_text())
    out: list[SignedOrder] = []
    for item in raw:
        order = RebalanceOrder(**item["order"])
        out.append(SignedOrder(
            order=order,
            algorithm=item["algorithm"],
            public_key_b64=item["public_key_b64"],
            signature_b64=item["signature_b64"],
            message_digest_sha256=item["message_digest_sha256"],
            slh_dsa_public_key_b64=item.get("slh_dsa_public_key_b64"),
            slh_dsa_signature_b64=item.get("slh_dsa_signature_b64"),
            ed25519_public_key_b64=item.get("ed25519_public_key_b64"),
            ed25519_signature_b64=item.get("ed25519_signature_b64"),
        ))
    return out
