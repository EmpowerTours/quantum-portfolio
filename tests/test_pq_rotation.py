"""Reconfiguration statements for MLDSAAttestationV2.

Run with:  ./.venv/bin/pytest tests/test_pq_rotation.py -q
"""
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import pq_rotation as rot, pq_signing as pq

# --- parity goldens ------------------------------------------------------
# Statements are domain-separated by (chain_id, contract), so a golden is only
# meaningful for a FIXED pair. The matching Solidity assertions are in
# zk-mldsa/contracts/test/MLDSAAttestationV2Parity.t.sol.
#
# If one of these fails: do NOT update the golden. One of the two
# implementations has drifted, and a rotation signed against the drifted side
# reverts StatementMismatch AFTER a Groth16 proof has been paid for.
GOLDEN_CHAIN_ID = 143
GOLDEN_ADDR = "0x00000000000000000000000000000000000000A2"

GOLDEN_ADD_NONCE0 = "b81fc460ad77ceaed77fde8f091446556abc0f6c82c21aa6e949168661d05d46"
GOLDEN_REVOKE_NONCE7 = "b3462d0b550aecf777ae848537299f2512a19654d4d295bd03943dd6c7e4fda6"
GOLDEN_VETO_BIGNONCE = "5be4f50ec4f115316046526d3a17f77eb36fc81083c7217b5751ed06cc3277f0"
GOLDEN_SETGUARDIAN_NONCE0 = "78ccbd15b81729d9dfed0156056e87f1fb9adb916b549d59cad25bc0d3a38691"
GUARDIAN_ADDR = "0x000000000000000000000000000000000000dEaD"


def _h(action, subject, nonce):
    return rot.statement_hash(action, subject, nonce, GOLDEN_CHAIN_ID, GOLDEN_ADDR).hex()


def test_statement_hash_matches_solidity_golden():
    assert _h(rot.ACTION_ADD, "0x" + "11" * 32, 0) == GOLDEN_ADD_NONCE0
    assert _h(rot.ACTION_REVOKE, "0x" + "22" * 32, 7) == GOLDEN_REVOKE_NONCE7
    # 2**64 proves the nonce is a full uint256 on both sides.
    assert _h(rot.ACTION_VETO, "0x" + "33" * 32, 2**64) == GOLDEN_VETO_BIGNONCE
    assert _h(rot.ACTION_SET_GUARDIAN, GUARDIAN_ADDR, 0) == GOLDEN_SETGUARDIAN_NONCE0


def test_set_guardian_subject_is_a_left_padded_address():
    """The contract writes the guardian as bytes32(uint256(uint160(addr))).
    Both widths are accepted so an operator cannot sign for a different address
    by pasting the wrong one."""
    padded = rot.subject_for(rot.ACTION_SET_GUARDIAN, GUARDIAN_ADDR)
    assert len(padded) == 32
    assert padded[:12] == b"\x00" * 12
    assert padded[12:].hex() == GUARDIAN_ADDR[2:].lower()
    assert rot.subject_for(rot.ACTION_SET_GUARDIAN, "0x" + padded.hex()) == padded


@pytest.mark.parametrize("bad", [
    "0x" + "ff" * 32,   # 32 bytes but not a padded address
    "0x" + "ab" * 21,   # wrong width
])
def test_set_guardian_rejects_a_subject_that_is_not_an_address(bad):
    with pytest.raises(ValueError):
        rot.subject_for(rot.ACTION_SET_GUARDIAN, bad)


def test_set_guardian_action_is_distinct():
    """Action 4 must not collide with the key-fingerprint actions: a signature
    authorising a guardian change must never be replayable as a key change."""
    subj = rot.subject_for(rot.ACTION_SET_GUARDIAN, GUARDIAN_ADDR)
    hashes = {rot.statement_hash(a, subj, 0, 143, GOLDEN_ADDR)
              for a in (rot.ACTION_ADD, rot.ACTION_REVOKE, rot.ACTION_VETO,
                        rot.ACTION_SET_GUARDIAN)}
    assert len(hashes) == 4


def test_statement_layout_is_137_bytes():
    b = rot.statement_bytes(rot.ACTION_ADD, "0x" + "11" * 32, 0, 143, GOLDEN_ADDR)
    assert len(b) == rot.STATEMENT_LEN == 137
    assert b[:20] == b"MLDSA-ATTEST-V2-AUTH"
    assert b[20] == rot.ACTION_ADD
    assert int.from_bytes(b[21:53], "big") == 143
    assert b[53:73].hex() == GOLDEN_ADDR[2:].lower()
    assert int.from_bytes(b[73:105], "big") == 0
    assert b[105:137] == bytes.fromhex("11" * 32)


def test_statement_can_never_be_confused_with_an_order():
    """Canonical orders are compact JSON and begin with `{`; statements begin
    with the domain tag's `M`. That single byte is what makes it impossible to
    trick the agent into signing a rotation by handing it an order, or to
    replay a signed order as a rotation."""
    b = rot.statement_bytes(rot.ACTION_ADD, "0x" + "11" * 32, 0, 143, GOLDEN_ADDR)
    assert b[:1] == b"M"
    assert b[:1] != b"{"
    order_bytes = pq.canonical_bytes({"order_id": "x"})
    assert order_bytes[:1] == b"{"


@pytest.mark.parametrize("field,args", [
    ("action", (99, "0x" + "11" * 32, 0, 143, GOLDEN_ADDR)),
    ("nonce", (rot.ACTION_ADD, "0x" + "11" * 32, -1, 143, GOLDEN_ADDR)),
    ("chain_id", (rot.ACTION_ADD, "0x" + "11" * 32, 0, -1, GOLDEN_ADDR)),
    ("subject", (rot.ACTION_ADD, "0x" + "11" * 31, 0, 143, GOLDEN_ADDR)),
    ("contract", (rot.ACTION_ADD, "0x" + "11" * 32, 0, 143, "0xdeadbeef")),
])
def test_rejects_malformed_fields(field, args):
    with pytest.raises(ValueError):
        rot.statement_bytes(*args)


def test_every_field_changes_the_hash():
    """Each bound field must actually reach the digest. A field that is in the
    layout but not in the hash is a replay guard that does not guard."""
    base = dict(action=rot.ACTION_ADD, subject="0x" + "11" * 32, nonce=0,
                chain_id=143, contract=GOLDEN_ADDR)
    h0 = rot.statement_hash(**base)
    variants = [
        {**base, "action": rot.ACTION_REVOKE},
        {**base, "subject": "0x" + "12" * 32},
        {**base, "nonce": 1},
        {**base, "chain_id": 10143},
        {**base, "contract": "0x00000000000000000000000000000000000000A3"},
    ]
    hashes = {rot.statement_hash(**v) for v in variants}
    assert h0 not in hashes
    assert len(hashes) == len(variants)


def test_sign_statement_round_trips_and_commits_what_the_guest_will():
    """The guest commits (sha256(msg), sha256(pk)). `sign_statement` must emit
    exactly the msg the contract recomputes, and a signature over it that
    verifies — otherwise the zkVM panics after the proof is paid for."""
    kp = pq.generate_keypair()
    inp = rot.sign_statement(rot.ACTION_ADD, "0x" + "11" * 32, 0, 143,
                             GOLDEN_ADDR, kp.sk, kp.pk)

    msg = bytes.fromhex(inp["msg_hex"])
    assert msg == rot.statement_bytes(rot.ACTION_ADD, "0x" + "11" * 32, 0, 143, GOLDEN_ADDR)
    assert pq.verify_bytes(msg, bytes.fromhex(inp["sig_hex"]), bytes.fromhex(inp["pk_hex"]))

    # orderHash the guest will commit
    assert inp["digest"] == hashlib.sha256(msg).hexdigest()
    assert inp["digest"] == GOLDEN_ADD_NONCE0
    # pkHash the guest will commit, i.e. what isAgentPk() must return true for
    assert hashlib.sha256(kp.pk).hexdigest() == hashlib.sha256(bytes.fromhex(inp["pk_hex"])).hexdigest()


def test_sign_statement_rejects_a_mismatched_public_key():
    """Signing with one key and claiming another produces a proof that reverts
    UnknownSigner on chain. Catch it here, before proving."""
    kp = pq.generate_keypair()
    other = pq.generate_keypair()
    with pytest.raises(RuntimeError):
        rot.sign_statement(rot.ACTION_ADD, "0x" + "11" * 32, 0, 143,
                           GOLDEN_ADDR, kp.sk, other.pk)


def test_sign_bytes_is_not_canonical_json_signing():
    """`pq.sign` cannot be used for statements at all: `canonical_bytes`
    refuses raw `bytes` rather than stringifying them. So the two paths cannot
    be confused by accident — an operator who reaches for the wrong one gets a
    TypeError, not a signature over the wrong preimage. That is why
    `sign_bytes` exists as a separate entry point."""
    kp = pq.generate_keypair()
    msg = rot.statement_bytes(rot.ACTION_ADD, "0x" + "11" * 32, 0, 143, GOLDEN_ADDR)

    raw_sig = pq.sign_bytes(msg, kp.sk)
    assert pq.verify_bytes(msg, raw_sig, kp.pk)

    with pytest.raises(TypeError):
        pq.canonical_bytes(msg)
    with pytest.raises(TypeError):
        pq.sign(msg, kp.sk)


def test_verify_bytes_rejects_tampering():
    kp = pq.generate_keypair()
    msg = rot.statement_bytes(rot.ACTION_ADD, "0x" + "11" * 32, 0, 143, GOLDEN_ADDR)
    sig = pq.sign_bytes(msg, kp.sk)

    # A statement for a different subject, same signature.
    other = rot.statement_bytes(rot.ACTION_ADD, "0x" + "12" * 32, 0, 143, GOLDEN_ADDR)
    assert not pq.verify_bytes(other, sig, kp.pk)
    # Right statement, wrong key.
    assert not pq.verify_bytes(msg, sig, pq.generate_keypair().pk)
    # Caller-side type errors must raise, not return False — a bug in the
    # caller must not look like a bad signature.
    with pytest.raises(TypeError):
        pq.verify_bytes(msg, sig, None)
