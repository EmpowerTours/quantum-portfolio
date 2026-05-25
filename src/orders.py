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
import hashlib
import json
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
    order: RebalanceOrder
    algorithm: str
    public_key_b64: str
    signature_b64: str
    message_digest_sha256: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "order": self.order.to_dict(),
            "algorithm": self.algorithm,
            "public_key_b64": self.public_key_b64,
            "signature_b64": self.signature_b64,
            "message_digest_sha256": self.message_digest_sha256,
        }


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


def verify_signed_order(signed: SignedOrder) -> bool:
    """Verify a signed order against its bundled public key."""
    pk = base64.b64decode(signed.public_key_b64)
    sig = base64.b64decode(signed.signature_b64)
    return pq.verify(signed.order.to_dict(), sig, pk)


def _last_line_hash(log_path: Path) -> str:
    """Return SHA-256 of the last non-empty line of the log, or genesis."""
    if not log_path.exists() or log_path.stat().st_size == 0:
        return GENESIS_PREV_HASH
    with log_path.open("rb") as fh:
        # Read from the end backwards a chunk at a time. The log lines are
        # ~5 KB each in the worst case, so 64 KB always covers the last one.
        try:
            fh.seek(-65536, 2)
        except OSError:
            fh.seek(0)
        chunk = fh.read()
    lines = [ln for ln in chunk.splitlines() if ln.strip()]
    if not lines:
        return GENESIS_PREV_HASH
    return hashlib.sha256(lines[-1]).hexdigest()


def append_audit(signed: SignedOrder,
                 log_path: Path = AUDIT_LOG_PATH,
                 verified: bool | None = None) -> None:
    """Append the signed order to the audit log, hash-chained to the
    previous entry. Creates the file if needed.

    Each entry stores `prev_hash` = SHA-256 of the previous line's bytes.
    Deleting or reordering lines invalidates the chain and is detected by
    `verify_audit_chain()`.
    """
    log_path.parent.mkdir(parents=True, exist_ok=True)
    entry = signed.to_dict()
    entry["verified_at_sign_time"] = (
        bool(verified) if verified is not None else verify_signed_order(signed)
    )
    entry["prev_hash"] = _last_line_hash(log_path)
    line = json.dumps(entry, separators=(",", ":"))
    with log_path.open("a") as fh:
        fh.write(line + "\n")


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
        ))
    return out
