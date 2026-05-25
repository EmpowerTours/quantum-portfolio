"""Rebalance-order schema, audit log, and replay protection.

An *order* is the off-chain instruction the agent issues before submitting
an on-chain transaction:

    {
      "order_id": "<uuid4>",
      "issued_at": "<iso8601>",
      "agent_id":  "<short label>",
      "pools":     ["GLD", "SLV", "NVDA"],
      "weights":   [0.333, 0.333, 0.333],
      "expected_return":  0.0432,
      "expected_vol":     0.1521,
      "qpu_job_id": "d88f7sdg7okc73enff00",   // null if purely classical
      "qaoa_p_optimal":   0.0066,             // null if not from QAOA
      "nonce":     "<uuid4>"
    }

Two artefacts are produced for every signed order:
  outputs/signed_orders.json  — list of every order + signature + verification status
  outputs/audit_log.jsonl     — append-only JSON-lines audit trail; one entry per order

Replay protection: every load of the log seeds a set of seen nonces.
"""
from __future__ import annotations

import base64
import datetime as dt
import json
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable

from . import pq_signing as pq

DEFAULT_AGENT_ID = "empowertours-quantum-portfolio-v0.1"
SIGNED_ORDERS_PATH = Path("outputs/signed_orders.json")
AUDIT_LOG_PATH     = Path("outputs/audit_log.jsonl")


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


def append_audit(signed: SignedOrder,
                 log_path: Path = AUDIT_LOG_PATH,
                 verified: bool | None = None) -> None:
    """Append the signed order to the audit log. Creates the file if needed."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    entry = signed.to_dict()
    entry["verified_at_sign_time"] = (
        bool(verified) if verified is not None else verify_signed_order(signed)
    )
    with log_path.open("a") as fh:
        fh.write(json.dumps(entry, separators=(",", ":")) + "\n")


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
