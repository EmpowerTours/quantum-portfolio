"""Regression tests for the audit-log hash chain.

Z-5: the writer (`_last_line_hash`) and the verifier (`verify_audit_chain`)
must normalise a line identically. They did not — the verifier used
`.strip()` while the writer used `rstrip(b"\r\n")`, which keeps leading and
trailing spaces and tabs. A legal JSONL line with trailing whitespace made
them chain from different digests, so the NEXT append silently broke the
chain even though every signature was valid.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import orders


def _write(tmp_path: Path, payload: dict, terminator: bytes) -> Path:
    line = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    p = tmp_path / "audit.jsonl"
    p.write_bytes(line.encode() + terminator)
    return p


@pytest.mark.parametrize("terminator", [
    b"\n",           # clean
    b"   \n",        # trailing spaces
    b"\t\n",         # trailing tab
    b"\r\n",         # CRLF
    b" \r\n",        # space + CRLF
])
def test_writer_and_verifier_agree_on_line_normalisation(tmp_path, terminator):
    """Whatever trailing whitespace a line carries, the digest the writer
    chains from must equal the one the verifier recomputes."""
    payload = {"prev_hash": orders.GENESIS_PREV_HASH, "x": 1}
    p = _write(tmp_path, payload, terminator)

    writer = orders._last_line_hash(p)
    canonical = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    verifier = hashlib.sha256(canonical).hexdigest()

    assert writer == verifier, (
        f"terminator {terminator!r}: writer chains from {writer[:16]}… but "
        f"verify_audit_chain expects {verifier[:16]}…"
    )


def test_empty_and_missing_log_return_genesis(tmp_path):
    missing = tmp_path / "nope.jsonl"
    assert orders._last_line_hash(missing) == orders.GENESIS_PREV_HASH
    empty = tmp_path / "empty.jsonl"
    empty.write_bytes(b"")
    assert orders._last_line_hash(empty) == orders.GENESIS_PREV_HASH
    blank = tmp_path / "blank.jsonl"
    blank.write_bytes(b"   \n\n  \n")
    assert orders._last_line_hash(blank) == orders.GENESIS_PREV_HASH


def test_long_line_beyond_the_initial_window(tmp_path):
    """The doubling reverse-scan must find a complete trailing line even when
    it exceeds the 8 KB starting window — a truncated fragment would hash to
    something the verifier never computes."""
    payload = {"prev_hash": orders.GENESIS_PREV_HASH, "blob": "A" * 40_000}
    p = _write(tmp_path, payload, b"\n")
    canonical = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    assert orders._last_line_hash(p) == hashlib.sha256(canonical).hexdigest()


def test_shipped_audit_log_still_verifies():
    """The live log must not be invalidated by the normalisation change."""
    ok, n, reason = orders.verify_audit_chain()
    assert ok, f"shipped audit log broke: {reason}"
    assert n > 0
