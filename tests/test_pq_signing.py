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

def test_slh_dsa_variant_is_shake_256s_not_128s():
    """Lock in the SLH-DSA parameter set. quantcrypt's `SMALL_SPHINCS` maps to
    PQClean's `sphincs-shake-256s-simple` — the Level-5 (256-bit) small
    variant, NOT the Level-1 (128-bit) variant. FIPS 205 parameter table:

      SHAKE-128s: pk=32  sk=64   sig=7856   (Level-1)
      SHAKE-256s: pk=64  sk=128  sig=29792  (Level-5)

    Our shipped sizes match 256s. This test guards against a future
    quantcrypt update introducing a real 128s class and a refactor
    silently re-labelling the hedge as the wrong (weaker) parameter set.
    """
    kp = pq.slh_dsa_generate_keypair()
    sig = pq.slh_dsa_sign({"x": 1}, kp.sk)
    # FIPS 205 SHAKE-256s sizes — distinguishes from 128s in one assertion each.
    assert len(kp.pk) == 64, "pk size matches SHAKE-256s (128s would be 32 B)"
    assert len(kp.sk) == 128, "sk size matches SHAKE-256s (128s would be 64 B)"
    assert len(sig) == 29792, "sig length matches SHAKE-256s (128s would be 7856 B)"
    assert "256s" in pq.SLH_DSA_ALGORITHM, f"algo label must say 256s, got: {pq.SLH_DSA_ALGORITHM}"


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


# --- Schema-version policy ------------------------------------------------

def test_future_schema_version_rejected():
    """An order with schema_version > current SCHEMA_VERSION must fail
    verification — we cannot reason about fields we do not know how to
    canonicalise. Pre-fix this was only documented, not enforced."""
    kp = pq.generate_keypair()
    order = orders.RebalanceOrder(
        pools=["AAPL"], weights=[1.0],
        expected_return=0.1, expected_vol=0.2,
        schema_version=orders.SCHEMA_VERSION + 99,
    )
    signed = orders.sign_order(order, kp, seen_nonces=set())
    # Signature itself is valid (signer used schema=100); receiver MUST
    # still refuse because future fields might silently desync.
    assert not orders.verify_signed_order(signed), (
        "verify_signed_order accepted a future schema_version - the "
        "documented policy in src/orders.py:23 is now unenforced"
    )


def test_current_schema_version_accepted():
    """Sanity check: SCHEMA_VERSION (current) verifies. Catches a
    regression where the future-check above accidentally rejects today."""
    kp = pq.generate_keypair()
    order = orders.RebalanceOrder(
        pools=["AAPL"], weights=[1.0],
        expected_return=0.1, expected_vol=0.2,
        schema_version=orders.SCHEMA_VERSION,
    )
    signed = orders.sign_order(order, kp, seen_nonces=set())
    assert orders.verify_signed_order(signed)


# --- B3: append_audit concurrency under flock -----------------------------

def test_concurrent_append_audit_preserves_chain(tmp_path: Path | None = None):
    """Two concurrent append_audit calls must serialise correctly.

    The previous (unlocked) implementation could let two callers read the
    same prev_hash and append entries pointing to the same predecessor,
    irrecoverably breaking the chain. With POSIX flock the second writer
    waits for the first to flush, picks up the updated prev_hash, and
    verify_audit_chain returns True with n == 2.
    """
    import threading
    if tmp_path is None:
        tmp_path = Path(tempfile.mkdtemp())
    log = tmp_path / "audit_race.jsonl"
    try:
        ml_kp = pq.ensure_keypair(tmp_path)
        slh_kp = pq.slh_dsa_ensure_keypair(tmp_path)
        ed_kp = pq.ed25519_ensure_keypair(tmp_path)

        signed_orders_list = []
        for i in range(2):
            o = orders.RebalanceOrder(
                pools=[f"R{i}"], weights=[1.0],
                expected_return=0.05, expected_vol=0.10,
            )
            signed_orders_list.append(
                orders.sign_order_hedged(o, ml_kp, slh_kp, ed_kp, seen_nonces=set())
            )

        barrier = threading.Barrier(2)
        errors: list[Exception] = []

        def worker(s: orders.SignedOrder) -> None:
            try:
                barrier.wait()
                orders.append_audit(s, log_path=log)
            except Exception as exc:  # noqa: BLE001
                errors.append(exc)

        threads = [threading.Thread(target=worker, args=(s,))
                   for s in signed_orders_list]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert not errors, f"concurrent workers raised: {errors!r}"
        ok, n, reason = orders.verify_audit_chain(log)
        assert ok, f"concurrent appends broke the chain: {reason}"
        assert n == 2, f"expected 2 entries, got {n}"
    finally:
        shutil.rmtree(tmp_path, ignore_errors=True)


# --- H4: reverse-line scan past the old 64 KB invariant -------------------

def test_last_line_hash_survives_huge_lines(tmp_path: Path | None = None):
    """The doubling-window reverse scan must find the last line even when
    individual entries exceed the previous 64 KB buffer. We synthesise a
    log with one ~80 KB entry — the old fixed-window implementation
    would return the SHA-256 of a truncated fragment for this file."""
    import hashlib as _hl
    if tmp_path is None:
        tmp_path = Path(tempfile.mkdtemp())
    log = tmp_path / "huge.jsonl"
    try:
        big_entry = '{"x":"' + ("A" * 80_000) + '"}'
        log.write_text(big_entry + "\n")
        expected = _hl.sha256(big_entry.encode("utf-8")).hexdigest()
        assert orders._last_line_hash(log) == expected
    finally:
        shutil.rmtree(tmp_path, ignore_errors=True)


# --- H6: append_audit fails closed on a bad signature ---------------------

def test_append_audit_refuses_unverifiable_order(tmp_path: Path | None = None):
    """A post-sign verify failure is a bug — append_audit must raise rather
    than write a 'verified_at_sign_time=False' entry that still burns the
    nonce in _load_seen_nonces."""
    if tmp_path is None:
        tmp_path = Path(tempfile.mkdtemp())
    log = tmp_path / "audit.jsonl"
    try:
        kp = pq.ensure_keypair(tmp_path)
        order = orders.RebalanceOrder(
            pools=["GLD"], weights=[1.0],
            expected_return=0.05, expected_vol=0.10,
        )
        signed = orders.sign_order(order, kp, seen_nonces=set())
        # Tamper after-the-fact so the verify call inside append_audit fails.
        signed.order.weights = [0.5]
        try:
            orders.append_audit(signed, log_path=log)
        except orders.AuditVerifyFailed:
            pass
        else:
            raise AssertionError("append_audit accepted an unverifiable order")
        assert not log.exists(), "audit log was created despite verify failure"
    finally:
        shutil.rmtree(tmp_path, ignore_errors=True)


# --- H2: walk-forward forecaster has no future-price lookahead ------------

def test_walk_forward_has_no_lookahead():
    """Future prices after as_of must not influence training-row selection.

    Construct two price series identical through `as_of + horizon_days`,
    then diverge wildly. A lookahead-free walk-forward forecaster sees
    only the identical prefix and produces an identical prediction at
    as_of. The pre-fix implementation used `df.index <= as_of`, letting
    the last `horizon_days` training rows consume prices strictly past
    as_of — directly observable here.
    """
    import numpy as np
    import pandas as pd
    from src.ai_forecast import _train_one_asset

    dates = pd.date_range("2024-01-01", periods=400, freq="B")
    rng = np.random.default_rng(42)
    rets = rng.normal(0, 0.01, size=400)
    prices = pd.Series(np.cumprod(1 + rets) * 100.0, index=dates)

    as_of = dates[250]
    horizon = 21

    y_clean, _ = _train_one_asset(prices, as_of, horizon)

    prices_corrupt = prices.copy()
    # Corrupt strictly AFTER as_of. With the lookahead fix, training
    # consumes prices through position (250 - horizon + horizon) = 250 only,
    # so corruption at 251+ is invisible. Without the fix, training rows
    # at positions 230..250 use corrupted prices at 251..271 → different y.
    prices_corrupt.iloc[251:] = prices_corrupt.iloc[251:] * 100.0
    y_corrupt, _ = _train_one_asset(prices_corrupt, as_of, horizon)

    assert abs(y_clean - y_corrupt) < 1e-12, (
        f"future-price corruption changed walk-forward prediction "
        f"(lookahead leak): clean={y_clean:.6g} corrupt={y_corrupt:.6g}"
    )


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
