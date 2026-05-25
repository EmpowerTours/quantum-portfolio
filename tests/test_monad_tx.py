"""Round-trip tests for the Monad unsigned-TX builder."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import monad_tx as mtx
from src import orders, pq_signing as pq


SELF_ADDR = "0x1111111111111111111111111111111111111111"


def _make_signed_order() -> orders.SignedOrder:
    kp = pq.generate_keypair()
    order = orders.RebalanceOrder(
        pools=["GLD", "SLV", "NVDA"], weights=[1/3, 1/3, 1/3],
        expected_return=0.05, expected_vol=0.15,
        qpu_job_id="d88f7sdg7okc73enff00", qaoa_p_optimal=0.0066,
    )
    return orders.sign_order(order, kp, seen_nonces=set())


def test_calldata_roundtrip():
    signed = _make_signed_order()
    blob = mtx.encode_order_calldata(signed)
    assert blob.startswith("0x")
    order_d, sig, pk = mtx.decode_order_calldata(blob)
    assert order_d["pools"] == signed.order.pools
    assert order_d["nonce"] == signed.order.nonce
    assert order_d["qpu_job_id"] == "d88f7sdg7okc73enff00"
    # Bytes survive the round trip exactly
    import base64
    assert sig == base64.b64decode(signed.signature_b64)
    assert pk  == base64.b64decode(signed.public_key_b64)


def test_unsigned_tx_fields():
    signed = _make_signed_order()
    tx = mtx.build_unsigned_tx(signed, to_address=SELF_ADDR, nonce=7)
    assert tx.chainId == mtx.MONAD_CHAIN_ID
    assert tx.type == 2
    assert tx.nonce == 7
    assert tx.maxFeePerGas == mtx.DEFAULT_MAX_FEE_GWEI * 10**9
    assert tx.maxPriorityFeePerGas == mtx.DEFAULT_PRIORITY_GWEI * 10**9
    assert tx.gas == mtx.DEFAULT_GAS_LIMIT
    assert tx.to == SELF_ADDR
    assert tx.value == 0
    # ASCII for 'PQO1' = 0x50 0x51 0x4f 0x31
    assert tx.data.startswith("0x50514f31"), f"magic 'PQO1' missing: {tx.data[:12]}"
    assert tx.accessList == []


def test_unsigned_tx_rejects_bad_address():
    signed = _make_signed_order()
    try:
        mtx.build_unsigned_tx(signed, to_address="not-a-hex-address", nonce=0)
    except ValueError:
        return
    raise AssertionError("expected ValueError on malformed to_address")


def test_calldata_detects_corruption():
    signed = _make_signed_order()
    blob = mtx.encode_order_calldata(signed)
    # Flip a byte inside the order JSON region (skip the magic).
    raw = bytearray.fromhex(blob[2:])
    raw[20] ^= 0xFF
    corrupt = "0x" + bytes(raw).hex()
    try:
        mtx.decode_order_calldata(corrupt)
    except Exception:
        return
    raise AssertionError("decoder accepted a corrupted blob")


if __name__ == "__main__":
    tests = [v for k, v in globals().items() if k.startswith("test_") and callable(v)]
    failures = 0
    for t in tests:
        try:
            t()
            print(f"  PASS  {t.__name__}")
        except AssertionError as e:
            failures += 1
            print(f"  FAIL  {t.__name__}  {e}")
        except Exception as e:
            failures += 1
            print(f"  ERROR {t.__name__}  {type(e).__name__}: {e}")
    print(f"\n{'OK' if failures == 0 else f'{failures} failures'}")
    sys.exit(failures)
