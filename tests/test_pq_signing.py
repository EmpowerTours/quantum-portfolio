"""Round-trip + tampering tests for the PQ signing layer.

Run with:  python -m pytest tests/  (or just python tests/test_pq_signing.py)
"""
from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import orders, pq_signing as pq


def test_keypair_sizes_match_fips_204():
    kp = pq.generate_keypair()
    assert len(kp.pk) == pq.PUBLIC_KEY_BYTES == 1952
    assert len(kp.sk) == pq.SECRET_KEY_BYTES == 4032


def test_sign_verify_roundtrip():
    kp = pq.generate_keypair()
    msg = {"pools": ["GLD", "SLV"], "weights": [0.5, 0.5]}
    sig = pq.sign(msg, kp.sk)
    assert pq.verify(msg, sig, kp.pk)


def test_tampered_payload_fails():
    kp = pq.generate_keypair()
    msg = {"pools": ["GLD", "SLV"], "weights": [0.5, 0.5]}
    sig = pq.sign(msg, kp.sk)
    tampered = {"pools": ["GLD", "AAPL"], "weights": [0.5, 0.5]}
    assert not pq.verify(tampered, sig, kp.pk)


def test_swapped_pubkey_fails():
    kp1 = pq.generate_keypair()
    kp2 = pq.generate_keypair()
    msg = {"order": 1}
    sig = pq.sign(msg, kp1.sk)
    assert not pq.verify(msg, sig, kp2.pk)


def test_keypair_persistence(tmp_path: Path | None = None):
    if tmp_path is None:
        tmp_path = Path(tempfile.mkdtemp())
    try:
        kp = pq.ensure_keypair(tmp_path)
        reloaded = pq.load_keypair(tmp_path)
        assert kp.pk == reloaded.pk
        assert kp.sk == reloaded.sk
        # secret-key file must be 0600
        sk_path = tmp_path / "pq.sec"
        mode = oct(sk_path.stat().st_mode & 0o777)
        assert mode == "0o600", f"sk file mode {mode} is not 0600"
    finally:
        shutil.rmtree(tmp_path, ignore_errors=True)


def test_signed_order_roundtrip(tmp_path: Path | None = None):
    if tmp_path is None:
        tmp_path = Path(tempfile.mkdtemp())
    try:
        kp = pq.ensure_keypair(tmp_path)
        order = orders.RebalanceOrder(
            pools=["GLD", "SLV", "NVDA"], weights=[1/3, 1/3, 1/3],
            expected_return=0.05, expected_vol=0.15,
            qpu_job_id="d88f7sdg7okc73enff00", qaoa_p_optimal=0.0066,
        )
        signed = orders.sign_order(order, kp, seen_nonces=set())
        assert orders.verify_signed_order(signed)
        # mutate a field and re-verify
        signed.order.weights[0] = 0.99
        assert not orders.verify_signed_order(signed)
    finally:
        shutil.rmtree(tmp_path, ignore_errors=True)


def test_nonce_replay_rejected(tmp_path: Path | None = None):
    if tmp_path is None:
        tmp_path = Path(tempfile.mkdtemp())
    try:
        kp = pq.ensure_keypair(tmp_path)
        order = orders.RebalanceOrder(
            pools=["AAPL"], weights=[1.0], expected_return=0.1, expected_vol=0.2,
        )
        seen = {order.nonce}
        try:
            orders.sign_order(order, kp, seen_nonces=seen)
        except orders.NonceSeenError:
            return
        raise AssertionError("NonceSeenError not raised on replay")
    finally:
        shutil.rmtree(tmp_path, ignore_errors=True)


def test_schema_version_is_signed():
    """If schema_version is mutated post-signing, verify must fail."""
    kp = pq.generate_keypair()
    order = orders.RebalanceOrder(
        pools=["GLD"], weights=[1.0], expected_return=0.05, expected_vol=0.1,
    )
    signed = orders.sign_order(order, kp, seen_nonces=set())
    assert signed.order.schema_version == orders.SCHEMA_VERSION
    assert orders.verify_signed_order(signed)
    signed.order.schema_version = orders.SCHEMA_VERSION + 99
    assert not orders.verify_signed_order(signed)


def test_canonical_bytes_rejects_unknown_types():
    """No silent stringification — unknown types must raise loudly."""
    import datetime as _dt
    try:
        pq.canonical_bytes({"when": _dt.datetime(2026, 1, 1)})
    except TypeError as e:
        assert "datetime" in str(e), f"unexpected message: {e}"
        return
    raise AssertionError("canonical_bytes silently accepted a datetime")


def test_verify_strict_type_errors():
    """Caller bugs raise; only legitimate verification failures return False."""
    kp = pq.generate_keypair()
    try:
        pq.verify({"a": 1}, None, kp.pk)
    except TypeError:
        pass
    else:
        raise AssertionError("verify accepted None signature")

    try:
        pq.verify({"a": 1}, "not bytes", kp.pk)
    except TypeError:
        pass
    else:
        raise AssertionError("verify accepted non-bytes signature")

    # Wrong-length pk is legitimate "no", not a programmer error.
    assert not pq.verify({"a": 1}, b"\x00" * 10, b"\x00" * 100)


def test_audit_chain_intact(tmp_path: Path | None = None):
    """Append three orders and verify the hash chain links cleanly."""
    if tmp_path is None:
        tmp_path = Path(tempfile.mkdtemp())
    log = tmp_path / "audit.jsonl"
    try:
        kp = pq.ensure_keypair(tmp_path)
        for i in range(3):
            o = orders.RebalanceOrder(
                pools=[f"P{i}"], weights=[1.0], expected_return=0.0, expected_vol=0.0,
            )
            orders.append_audit(orders.sign_order(o, kp, seen_nonces=set()), log)
        ok, n, reason = orders.verify_audit_chain(log)
        assert ok, f"chain broken on clean append: {reason}"
        assert n == 3, f"expected 3 entries, got {n}"
    finally:
        shutil.rmtree(tmp_path, ignore_errors=True)


def test_audit_chain_detects_deletion(tmp_path: Path | None = None):
    """Deleting a middle line must break the chain."""
    if tmp_path is None:
        tmp_path = Path(tempfile.mkdtemp())
    log = tmp_path / "audit.jsonl"
    try:
        kp = pq.ensure_keypair(tmp_path)
        for i in range(3):
            o = orders.RebalanceOrder(
                pools=[f"P{i}"], weights=[1.0], expected_return=0.0, expected_vol=0.0,
            )
            orders.append_audit(orders.sign_order(o, kp, seen_nonces=set()), log)
        # Delete the middle line.
        lines = log.read_text().strip().splitlines()
        log.write_text(lines[0] + "\n" + lines[2] + "\n")
        ok, n, reason = orders.verify_audit_chain(log)
        assert not ok, "chain verification incorrectly accepted a deleted middle line"
        assert "mismatch" in reason, f"unexpected failure reason: {reason}"
    finally:
        shutil.rmtree(tmp_path, ignore_errors=True)


# --- SLH-DSA hedge (hash-based PQ, independent assumption) ----------------

def test_slh_dsa_sign_verify_roundtrip():
    kp = pq.slh_dsa_generate_keypair()
    assert len(kp.pk) == pq.SLH_DSA_PUBLIC_KEY_BYTES == 64
    assert len(kp.sk) == pq.SLH_DSA_SECRET_KEY_BYTES == 128
    msg = {"pools": ["GLD", "SLV"], "weights": [0.5, 0.5]}
    sig = pq.slh_dsa_sign(msg, kp.sk)
    assert pq.slh_dsa_verify(msg, sig, kp.pk)


def test_slh_dsa_tampered_payload_fails():
    kp = pq.slh_dsa_generate_keypair()
    msg = {"x": 1}
    sig = pq.slh_dsa_sign(msg, kp.sk)
    assert not pq.slh_dsa_verify({"x": 2}, sig, kp.pk)


# --- Ed25519 classical leg ------------------------------------------------

def test_ed25519_sign_verify_roundtrip():
    kp = pq.ed25519_generate_keypair()
    assert len(kp.pk) == pq.ED25519_PUBLIC_KEY_BYTES == 32
    assert len(kp.sk) == pq.ED25519_SECRET_KEY_BYTES == 32
    msg = {"pools": ["GLD", "SLV"], "weights": [0.5, 0.5]}
    sig = pq.ed25519_sign(msg, kp.sk)
    assert len(sig) == pq.ED25519_SIGNATURE_BYTES == 64
    assert pq.ed25519_verify(msg, sig, kp.pk)


def test_ed25519_tampered_payload_fails():
    kp = pq.ed25519_generate_keypair()
    msg = {"x": 1}
    sig = pq.ed25519_sign(msg, kp.sk)
    assert not pq.ed25519_verify({"x": 2}, sig, kp.pk)


# --- Hedged order: ML-DSA + SLH-DSA + Ed25519 -----------------------------

def test_hedged_order_roundtrip(tmp_path: Path | None = None):
    if tmp_path is None:
        tmp_path = Path(tempfile.mkdtemp())
    try:
        ml = pq.ensure_keypair(tmp_path)
        slh = pq.slh_dsa_ensure_keypair(tmp_path)
        ed = pq.ed25519_ensure_keypair(tmp_path)
        order = orders.RebalanceOrder(
            pools=["GLD", "SLV", "NVDA"], weights=[1/3, 1/3, 1/3],
            expected_return=0.05, expected_vol=0.15,
            qpu_job_id="d89rmk1789is7393mlr0", qaoa_p_optimal=0.0051,
        )
        signed = orders.sign_order_hedged(order, ml, slh, ed, seen_nonces=set())
        assert signed.is_hedged
        assert orders.verify_signed_order(signed)
        comp = orders.verify_signed_order_components(signed)
        assert comp == {"ml_dsa": True, "slh_dsa": True, "ed25519": True}
    finally:
        shutil.rmtree(tmp_path, ignore_errors=True)


def test_hedged_tamper_breaks_all_signatures(tmp_path: Path | None = None):
    """Tampering a single field invalidates every signature scheme."""
    if tmp_path is None:
        tmp_path = Path(tempfile.mkdtemp())
    try:
        ml = pq.ensure_keypair(tmp_path)
        slh = pq.slh_dsa_ensure_keypair(tmp_path)
        ed = pq.ed25519_ensure_keypair(tmp_path)
        order = orders.RebalanceOrder(
            pools=["GLD"], weights=[1.0], expected_return=0.05, expected_vol=0.1,
        )
        signed = orders.sign_order_hedged(order, ml, slh, ed, seen_nonces=set())
        signed.order.weights[0] = 0.99   # tamper
        assert not orders.verify_signed_order(signed)
        comp = orders.verify_signed_order_components(signed)
        assert comp == {"ml_dsa": False, "slh_dsa": False, "ed25519": False}
    finally:
        shutil.rmtree(tmp_path, ignore_errors=True)


def test_legacy_ml_dsa_only_order_still_verifies():
    """Backward-compat: an order signed only with ML-DSA (no hedge fields)
    must still verify under the new code path."""
    kp = pq.generate_keypair()
    order = orders.RebalanceOrder(
        pools=["AAPL"], weights=[1.0], expected_return=0.1, expected_vol=0.2,
    )
    signed = orders.sign_order(order, kp, seen_nonces=set())
    assert not signed.is_hedged
    assert orders.verify_signed_order(signed)


if __name__ == "__main__":
    # Run without pytest
    tests = [v for k, v in globals().items() if k.startswith("test_") and callable(v)]
    failures = 0
    for t in tests:
        name = t.__name__
        try:
            t()
            print(f"  PASS  {name}")
        except AssertionError as e:
            failures += 1
            print(f"  FAIL  {name}  {e}")
        except Exception as e:
            failures += 1
            print(f"  ERROR {name}  {type(e).__name__}: {e}")
    print(f"\n{'OK' if failures == 0 else f'{failures} failures'}")
    sys.exit(failures)
