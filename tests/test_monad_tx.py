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


# --- AuditAnchor integration ---------------------------------------------

ANCHOR_ADDR = "0xA1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1"


def test_order_sha256_matches_canonical_bytes():
    """order_sha256 must hash exactly the bytes a Solidity verifier would
    reconstruct from the on-chain calldata of the on-chain order TX."""
    import hashlib
    signed = _make_signed_order()
    expected = hashlib.sha256(pq.canonical_bytes(signed.order.to_dict())).digest()
    assert mtx.order_sha256(signed) == expected
    assert len(expected) == 32


def test_anchor_calldata_selector_no_seq():
    """anchor(bytes32) — selector 0xeecdf927, 36-byte calldata total."""
    signed = _make_signed_order()
    h = mtx.order_sha256(signed)
    blob = mtx.encode_anchor_calldata(h)
    raw = bytes.fromhex(blob[2:])
    assert len(raw) == 4 + 32, f"expected 36 bytes, got {len(raw)}"
    assert raw[:4] == bytes.fromhex("eecdf927"), "wrong anchor(bytes32) selector"
    assert raw[4:] == h


def test_anchor_calldata_selector_with_sequence():
    """anchor(bytes32, uint64) — selector 0xdb2c4aca, 68-byte calldata."""
    signed = _make_signed_order()
    h = mtx.order_sha256(signed)
    blob = mtx.encode_anchor_calldata(h, expected_sequence=42)
    raw = bytes.fromhex(blob[2:])
    assert len(raw) == 4 + 32 + 32, f"expected 68 bytes, got {len(raw)}"
    assert raw[:4] == bytes.fromhex("db2c4aca"), "wrong anchor(bytes32,uint64) selector"
    assert raw[4:36] == h
    # uint64 left-padded into a 32-byte word, big-endian
    seq_word = int.from_bytes(raw[36:68], "big")
    assert seq_word == 42


def test_anchor_calldata_rejects_bad_hash_length():
    try:
        mtx.encode_anchor_calldata(b"too short")
    except ValueError:
        return
    raise AssertionError("expected ValueError on non-32-byte hash")


def test_anchor_calldata_rejects_overflow_sequence():
    h = b"\x00" * 32
    try:
        mtx.encode_anchor_calldata(h, expected_sequence=2 ** 64)
    except ValueError:
        return
    raise AssertionError("expected ValueError on uint64 overflow")


def test_build_anchor_tx_field_shape():
    signed = _make_signed_order()
    tx = mtx.build_anchor_tx(
        signed, anchor_contract=ANCHOR_ADDR, nonce=3, expected_sequence=0,
    )
    assert tx.chainId == 143         # Monad mainnet
    assert tx.type == 2              # EIP-1559
    assert tx.to == ANCHOR_ADDR
    assert tx.value == 0
    assert tx.gas == mtx.ANCHOR_GAS_LIMIT
    assert tx.gas < 100_000, "anchor gas budget should fit the ~30K narrative"
    # Calldata begins with the with-sequence selector.
    assert tx.data.startswith("0xdb2c4aca")


def test_build_anchor_tx_rejects_bad_contract_address():
    signed = _make_signed_order()
    try:
        mtx.build_anchor_tx(signed, anchor_contract="0xnotanaddress", nonce=0)
    except ValueError:
        return
    raise AssertionError("expected ValueError on malformed anchor_contract")


def test_chain_id_is_monad_mainnet():
    """Independent assertion: MONAD_CHAIN_ID constant equals 143
    (Monad mainnet). Guards against a paste-typo to a testnet value."""
    assert mtx.MONAD_CHAIN_ID == 143, (
        f"MONAD_CHAIN_ID drifted: {mtx.MONAD_CHAIN_ID} (mainnet is 143)"
    )


# --- MonadAllocationVault integration ------------------------------------

VAULT_ADDR = "0xC39e298ce89cDfc934c697c9Fe0CC4BAA80B87f5"


def test_pool_label_hash_matches_solidity_keccak():
    """keccak256("Morpho STEAKETH (Monad)") must match the bytes the
    Solidity test computes for the same label string."""
    h = mtx.pool_label_hash("Morpho STEAKETH (Monad)")
    assert len(h) == 32
    # Verified by hand: keccak256("Morpho STEAKETH (Monad)") =
    expected = "9e9f3bf2e2cbe91454d6ed764dbea0ee7a3b0fbe6733abe791333f811ac71264"
    assert h.hex() == expected, f"keccak drift: {h.hex()} != {expected}"


def test_fractional_weights_to_bps_sums_to_10000():
    """Three equal-weight pools: 0.333.. each → 3334/3333/3333."""
    bps = mtx.fractional_weights_to_bps([1/3, 1/3, 1/3])
    assert sum(bps) == 10_000
    assert all(0 <= w <= 0xFFFF for w in bps)
    # One entry absorbs the +1 rounding remainder.
    assert sorted(bps) == [3333, 3333, 3334]


def test_fractional_weights_to_bps_handles_two_pools():
    bps = mtx.fractional_weights_to_bps([0.5, 0.5])
    assert sum(bps) == 10_000
    assert bps == [5000, 5000]


def test_fractional_weights_to_bps_rejects_zero_sum():
    """Pre-fix: [0,0,0] returned [10000,0,0], silently inflating pool 0
    to 100%. After fix: must raise so the on-chain Allocated event
    cannot misrepresent the agent's intent."""
    try:
        mtx.fractional_weights_to_bps([0.0, 0.0, 0.0])
    except ValueError as e:
        assert "0" in str(e).lower() or "sum" in str(e).lower()
        return
    raise AssertionError("expected ValueError on zero-sum weights")


def test_fractional_weights_to_bps_rejects_negative():
    """Negative weights are nonsense for portfolio allocations."""
    try:
        mtx.fractional_weights_to_bps([-0.1, 1.1])
    except ValueError:
        return
    raise AssertionError("expected ValueError on negative weight")


def test_alloc_calldata_selector_matches_forge_inspect():
    """ALLOC_EXECUTE_SELECTOR must equal the first 4 bytes of
    keccak256("execute(bytes32,bytes32[],uint16[])") — the value
    `forge inspect MonadAllocationVault methods` reports."""
    signed = _make_signed_order()
    h = mtx.order_sha256(signed)
    pools = [mtx.pool_label_hash(p) for p in signed.order.pools]
    weights = mtx.fractional_weights_to_bps(signed.order.weights)
    blob = mtx.encode_alloc_calldata(h, pools, weights)
    raw = bytes.fromhex(blob[2:])
    assert raw[:4] == bytes.fromhex("4a987805"), \
        f"wrong execute(bytes32,bytes32[],uint16[]) selector: {raw[:4].hex()}"


def test_alloc_calldata_rejects_length_mismatch():
    h = b"\x00" * 32
    try:
        mtx.encode_alloc_calldata(h, [b"\x00" * 32, b"\x01" * 32], [10_000])
    except ValueError:
        return
    raise AssertionError("expected ValueError on length mismatch")


def test_alloc_calldata_rejects_bad_weight_sum():
    h = b"\x00" * 32
    try:
        mtx.encode_alloc_calldata(h, [b"\x00" * 32], [9_999])
    except ValueError:
        return
    raise AssertionError("expected ValueError on weights != 10000")


def test_build_alloc_tx_field_shape():
    signed = _make_signed_order()
    tx = mtx.build_alloc_tx(
        signed,
        vault_contract=VAULT_ADDR,
        nonce=0,
        amount_wei=10**16,
        chain_id=mtx.MONAD_TESTNET_CHAIN_ID,
    )
    assert tx.chainId == 10143
    assert tx.to == VAULT_ADDR
    assert tx.value == 10**16
    assert tx.gas <= 250_000, "alloc gas budget exceeds reasonable bound"
    assert tx.data.startswith("0x4a987805")


def test_build_alloc_tx_rejects_zero_value():
    signed = _make_signed_order()
    try:
        mtx.build_alloc_tx(
            signed, vault_contract=VAULT_ADDR, nonce=0, amount_wei=0,
        )
    except ValueError:
        return
    raise AssertionError("expected ValueError on zero amount_wei")


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
