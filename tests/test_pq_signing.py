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
