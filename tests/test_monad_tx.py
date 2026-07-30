"""Round-trip tests for the Monad unsigned-TX builder."""
from __future__ import annotations

import time as _time

import pytest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import monad_tx as mtx
from src import orders, pq_signing as pq


SELF_ADDR = "0x1111111111111111111111111111111111111111"


_TEST_TRUSTED: orders.TrustedKeys | None = None


def _make_signed_order() -> orders.SignedOrder:
    """Sign with a throwaway keypair and record it as the trusted signer, so
    the builders' mandatory `trusted=` pin has something real to check."""
    global _TEST_TRUSTED
    kp = pq.generate_keypair()
    _TEST_TRUSTED = orders.TrustedKeys(
        ml_dsa=kp.pk,
        slh_dsa=b"\x00" * 64,
        ed25519=b"\x00" * 32,
    )
    order = orders.RebalanceOrder(
        pools=["GLD", "SLV", "NVDA"], weights=[1/3, 1/3, 1/3],
        expected_return=0.05, expected_vol=0.15,
        qpu_job_id="d88f7sdg7okc73enff00", qaoa_p_optimal=0.0066,
    )
    return orders.sign_order(order, kp, seen_nonces=set())


def test_calldata_roundtrip():
    signed = _make_signed_order()
    blob = mtx.encode_order_calldata(signed, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)
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
    tx = mtx.build_unsigned_tx(signed, to_address=SELF_ADDR, nonce=7, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)
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
        mtx.build_unsigned_tx(signed, to_address="not-a-hex-address", nonce=0, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)
    except ValueError:
        return
    raise AssertionError("expected ValueError on malformed to_address")


def test_calldata_detects_corruption():
    """Test-quality fix (per third-pass audit): a 0xFF XOR can leave
    valid UTF-8 and valid JSON, in which case the decoder returns
    successfully with corrupted content. The old test caught
    `except Exception` only and silently passed on the parsable-garbage
    branch. Strengthened: on a successful decode, the decoded order MUST
    differ from the signed order — corruption that round-trips bit-for-
    bit is the actual bug we want to catch."""
    signed = _make_signed_order()
    blob = mtx.encode_order_calldata(signed, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)
    original_dict = signed.order.to_dict()
    raw = bytearray.fromhex(blob[2:])
    raw[20] ^= 0xFF
    corrupt = "0x" + bytes(raw).hex()
    try:
        decoded_order, _sig, _pk = mtx.decode_order_calldata(corrupt)
    except Exception:
        return  # parse failure on the corrupted blob — also acceptable
    # Parsed successfully — verify the decoded content actually differs.
    assert decoded_order != original_dict, (
        "corruption round-tripped bit-for-bit: decoder accepted "
        "corrupted blob and produced the original order content - the "
        "encoding is malleable"
    )


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
        signed, anchor_contract=ANCHOR_ADDR, nonce=3, expected_sequence=0, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)
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
        mtx.build_anchor_tx(signed, anchor_contract="0xnotanaddress", nonce=0, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)
    except ValueError:
        return
    raise AssertionError("expected ValueError on malformed anchor_contract")


def test_builders_refuse_tampered_signed_order():
    """Cross-system audit #10: a remote attacker who writes to
    outputs/signed_orders.json could otherwise feed a tampered order
    into build_*_tx and anchor a forged SHA-256 on-chain. Every builder
    must verify the embedded PQ signature before serialising calldata.

    Constructs a valid SignedOrder, then mutates the order content
    so the signature no longer covers it. Every builder MUST raise
    UnverifiableOrder rather than produce calldata.
    """
    from dataclasses import replace
    signed = _make_signed_order()
    # Sanity: untampered signed order builds fine.
    mtx.encode_order_calldata(signed, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)
    mtx.build_alloc_tx(signed, vault_contract=VAULT_ADDR, nonce=0, amount_wei=1, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)
    mtx.build_anchor_tx(signed, anchor_contract=VAULT_ADDR, nonce=0, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)

    # Tamper: produce a SignedOrder whose order content no longer
    # matches the signature (pools list mutated).
    tampered_order = replace(signed.order, pools=["AAPL", "TSLA", "BTC"])
    tampered = replace(signed, order=tampered_order)
    assert not orders.verify_signed_order(tampered, require_hedged=False, require_execution=False), "test setup failed: tamper should invalidate"

    for fn_name, fn in [
        ("encode_order_calldata", lambda: mtx.encode_order_calldata(tampered, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)),
        ("build_alloc_tx",        lambda: mtx.build_alloc_tx(tampered, vault_contract=VAULT_ADDR, nonce=0, amount_wei=1, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)),
        ("build_anchor_tx",       lambda: mtx.build_anchor_tx(tampered, anchor_contract=VAULT_ADDR, nonce=0, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)),
        ("build_unsigned_tx",     lambda: mtx.build_unsigned_tx(tampered, to_address=SELF_ADDR, nonce=0, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)),
    ]:
        try:
            fn()
        except mtx.UnverifiableOrder:
            continue
        raise AssertionError(f"{fn_name} accepted tampered order without raising UnverifiableOrder")


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
        chain_id=mtx.MONAD_TESTNET_CHAIN_ID, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)
    assert tx.chainId == 10143
    assert tx.to == VAULT_ADDR
    assert tx.value == 10**16
    assert tx.gas <= 250_000, "alloc gas budget exceeds reasonable bound"
    assert tx.data.startswith("0x4a987805")


def test_build_alloc_tx_rejects_zero_value():
    signed = _make_signed_order()
    try:
        mtx.build_alloc_tx(
            signed, vault_contract=VAULT_ADDR, nonce=0, amount_wei=0, require_hedged=False, trusted=_TEST_TRUSTED, require_execution=False)
    except ValueError:
        return
    raise AssertionError("expected ValueError on zero amount_wei")


# --- UniswapRoutingVault route encoding ----------------------------------

# Golden generated with:
#   cast calldata "executeAndRoute(bytes32,address[],uint24[],uint16[],uint256[],uint256)" \
#     0x1111...1111 "[0x..aaAA,0x..bBbB]" "[3000,500]" "[6000,4000]" "[1000,2000]" 1893456000
ROUTE_GOLDEN = (
    "0x5caf7a40"
    "1111111111111111111111111111111111111111111111111111111111111111"
    "00000000000000000000000000000000000000000000000000000000000000c0"
    "0000000000000000000000000000000000000000000000000000000000000120"
    "0000000000000000000000000000000000000000000000000000000000000180"
    "00000000000000000000000000000000000000000000000000000000000001e0"
    "0000000000000000000000000000000000000000000000000000000070dbd880"
    "0000000000000000000000000000000000000000000000000000000000000002"
    "000000000000000000000000000000000000000000000000000000000000aaaa"
    "000000000000000000000000000000000000000000000000000000000000bbbb"
    "0000000000000000000000000000000000000000000000000000000000000002"
    "0000000000000000000000000000000000000000000000000000000000000bb8"
    "00000000000000000000000000000000000000000000000000000000000001f4"
    "0000000000000000000000000000000000000000000000000000000000000002"
    "0000000000000000000000000000000000000000000000000000000000001770"
    "0000000000000000000000000000000000000000000000000000000000000fa0"
    "0000000000000000000000000000000000000000000000000000000000000002"
    "00000000000000000000000000000000000000000000000000000000000003e8"
    "00000000000000000000000000000000000000000000000000000000000007d0"
)


def test_route_calldata_matches_cast_golden():
    blob = mtx.encode_route_calldata(
        order_hash=bytes.fromhex("11" * 32),
        token_outs=[
            "0x000000000000000000000000000000000000aaAA",
            "0x000000000000000000000000000000000000bBbB",
        ],
        fee_tiers=[3000, 500],
        weights_bps=[6000, 4000],
        amount_out_min=[1000, 2000],
        deadline=1893456000,
    )
    assert blob == ROUTE_GOLDEN, f"encoding drifted from cast golden:\n{blob}"


def test_route_calldata_rejects_bad_weights():
    try:
        mtx.encode_route_calldata(
            order_hash=bytes.fromhex("11" * 32),
            token_outs=["0x000000000000000000000000000000000000aaAA"],
            fee_tiers=[3000], weights_bps=[9999], amount_out_min=[0],
            deadline=1,
        )
    except ValueError:
        return
    raise AssertionError("expected ValueError on weights != 10000")


def test_route_calldata_rejects_length_mismatch():
    try:
        mtx.encode_route_calldata(
            order_hash=bytes.fromhex("11" * 32),
            token_outs=["0x000000000000000000000000000000000000aaAA"],
            fee_tiers=[3000, 500], weights_bps=[10000], amount_out_min=[0],
            deadline=1,
        )
    except ValueError:
        return
    raise AssertionError("expected ValueError on mismatched array lengths")


def _route_signed_order():
    """A schema-v2 order whose execution block IS the authorisation."""
    global _TEST_TRUSTED
    kp = pq.generate_keypair()
    _TEST_TRUSTED = orders.TrustedKeys(
        ml_dsa=kp.pk, slh_dsa=b"\x00" * 64, ed25519=b"\x00" * 32
    )
    ex = orders.RouteExecution(
        chain_id=mtx.MONAD_CHAIN_ID, vault=VAULT_ADDR, user=_AGENT,
        token_outs=[_USDC], fee_tiers=[3000], weights_bps=[10_000],
        amount_in_wei=10**17, amount_out_min=[2107],
        deadline=int(_time.time()) + 3600,
    )
    order = orders.RebalanceOrder(
        pools=["USDC"], weights=[1.0], expected_return=0.05, expected_vol=0.15,
        execution=ex,
    )
    return orders.sign_order(order, kp, seen_nonces=set()), ex


def test_build_route_tx_derives_everything_from_the_signed_execution():
    """Every route parameter must come from the PQ-signed execution block.

    This used to accept token_outs / fee_tiers / amount_out_min / deadline /
    amount_wei / vault as free caller kwargs and never read order.execution,
    so a verified order could be paired with a completely different trade.
    """
    signed, ex = _route_signed_order()
    tx = mtx.build_route_tx(signed, nonce=3, trusted=_TEST_TRUSTED, require_hedged=False)

    assert tx.chainId == ex.chain_id
    assert tx.to == ex.vault
    assert tx.value == ex.amount_in_wei
    assert tx.data.startswith("0x5caf7a40"), tx.data[:12]

    # The builder takes no route parameters at all any more.
    import inspect
    params = set(inspect.signature(mtx.build_route_tx).parameters)
    for leaked in ("token_outs", "fee_tiers", "amount_out_min", "deadline",
                   "amount_wei", "vault_contract"):
        assert leaked not in params, f"{leaked} must come from the signed order"


def test_build_route_tx_rejects_an_order_with_no_execution_block():
    signed = _make_signed_order()          # schema v2, execution=None
    try:
        mtx.build_route_tx(signed, nonce=0, trusted=_TEST_TRUSTED, require_hedged=False)
    except (ValueError, mtx.UnverifiableOrder):
        return
    raise AssertionError("expected refusal for an order carrying no execution block")


def test_anchor_v2_tx_carries_the_commitment_derived_from_the_signed_order():
    """Without this builder the whole execution binding was decorative: the
    commitment was computed, printed, and discarded, while the only anchor
    builders emitted V1 selectors carrying no commitment at all."""
    signed, ex = _route_signed_order()
    tx = mtx.build_anchor_v2_tx(
        signed, anchor_contract=VAULT_ADDR, nonce=0, expected_sequence=0,
        trusted=_TEST_TRUSTED, require_hedged=False,
    )
    assert tx.data.startswith("0x15954b2c"), "must call anchor(bytes32,bytes32,uint64)"
    body = tx.data[10:]
    assert body[0:64] == mtx.order_sha256(signed).hex()
    assert body[64:128] == mtx.route_commitment(ex, mtx.order_sha256(signed)).hex()
    assert int(body[128:192], 16) == 0
    assert tx.value == 0


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


# --- AuditAnchorV2 commitment parity -----------------------------------
#
# These goldens are asserted IDENTICALLY in Solidity
# (contracts/test/CommitmentParity.t.sol). The agent computes the commitment
# here and anchors it; the executor recomputes it on-chain and refuses to
# proceed on a mismatch. A silent divergence between the two implementations
# would not revert — it would permanently brick every order the agent signs,
# because a mis-committed anchor can never be re-anchored.
#
# If one of these fails: do NOT update the golden. One implementation drifted.

GOLDEN_ROUTE = "40fb62c19118b6aa2413dbbd0721005b61847a02bd7a7c7e4c5bb862ffb183ba"
GOLDEN_SUPPLY = "c51ff91d917e16305fef7efe869fc222ba736e34ae0608730ad96d217f268a6e"

_AGENT = "0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1"
_USDC = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"
_WETH = "0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242"
_WBTC = "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c"
_ORACLE = "0xff07261c87763cc5693ab78746d0b6735Ec626F5"
_IRM = "0x09475a3D6eA8c314c592b1a3799bDE044E2F400F"
_ZERO = "0x" + "0" * 40
# Commitments are domain-separated by (chain_id, executor), so the goldens are
# only meaningful for a pinned pair. These match contracts/test/CommitmentParity.
_GOLDEN_VAULT = "0x00000000000000000000000000000000000000AA"
_GOLDEN_ADAPTER = "0x00000000000000000000000000000000000000bb"
_GOLDEN_ORDER_HASH = bytes.fromhex("11" * 32)


def test_route_commitment_matches_solidity_golden():
    ex = orders.RouteExecution(
        chain_id=143, vault=_GOLDEN_VAULT, user=_AGENT,
        token_outs=[_USDC, _WETH], fee_tiers=[3000, 500], weights_bps=[6000, 4000],
        amount_in_wei=10**18, amount_out_min=[211166, 5000], deadline=1893456000,
    )
    assert mtx.route_commitment(ex, _GOLDEN_ORDER_HASH).hex() == GOLDEN_ROUTE


def test_supply_commitment_matches_solidity_golden():
    ex = orders.SupplyExecution(
        chain_id=143, adapter=_GOLDEN_ADAPTER, user=_AGENT,
        loan_token=_USDC, collateral_token=_WBTC, oracle=_ORACLE, irm=_IRM,
        lltv=860000000000000000, max_assets=2271,
    )
    assert mtx.supply_commitment(ex, _GOLDEN_ORDER_HASH).hex() == GOLDEN_SUPPLY


def test_route_commitment_is_bound_to_its_order_hash():
    """`consumed` is keyed by orderHash, so a commitment that did not name its
    own order could be filed under unlimited distinct orderHashes and executed
    once under each — N executions from one authorisation."""
    ex = orders.RouteExecution(
        chain_id=143, vault=_GOLDEN_VAULT, user=_AGENT,
        token_outs=[_USDC], fee_tiers=[3000], weights_bps=[10_000],
        amount_in_wei=10**18, amount_out_min=[1], deadline=1893456000,
    )
    a = mtx.route_commitment(ex, bytes.fromhex("11" * 32))
    b = mtx.route_commitment(ex, bytes.fromhex("22" * 32))
    assert a != b, "same trade under a different order must not share a commitment"


def test_route_commitment_is_order_sensitive():
    """A sum- or set-based commitment would pass this; abi.encode must not.
    Permuting the floors across legs is a different authorisation."""
    base = dict(
        chain_id=143, vault=_ZERO, user=_AGENT,
        token_outs=[_USDC, _WETH], fee_tiers=[3000, 500], weights_bps=[6000, 4000],
        amount_in_wei=10**18, deadline=1893456000,
    )
    a = mtx.route_commitment(orders.RouteExecution(amount_out_min=[211166, 5000], **base), _GOLDEN_ORDER_HASH)
    b = mtx.route_commitment(orders.RouteExecution(amount_out_min=[5000, 211166], **base), _GOLDEN_ORDER_HASH)
    assert a != b


def test_route_commitment_resists_array_boundary_migration():
    """The preimage runs weightsBps | amountInWei | amountOutMin, so one
    element can migrate across two boundaries at once. abi.encodePacked would
    make these identical; abi.encode must keep them distinct."""
    a = mtx.route_commitment(orders.RouteExecution(
        chain_id=143, vault=_ZERO, user=_AGENT,
        token_outs=[_USDC, _WETH], fee_tiers=[3000, 500], weights_bps=[3000, 7000],
        amount_in_wei=10**18, amount_out_min=[1, 2], deadline=1,
    ), _GOLDEN_ORDER_HASH)
    b = mtx.route_commitment(orders.RouteExecution(
        chain_id=143, vault=_ZERO, user=_AGENT,
        token_outs=[_USDC], fee_tiers=[3000], weights_bps=[3000],
        amount_in_wei=7000, amount_out_min=[10**18, 1, 2], deadline=1,
    ), _GOLDEN_ORDER_HASH)
    assert a != b


def test_validate_route_execution_catches_unanchorable_orders():
    """Anchoring a commitment the vault would reject bricks that orderHash
    permanently — AuditAnchorV2 refuses to re-anchor. These must be caught
    off-chain, before the anchor transaction is built."""
    def ex(**over):
        base = dict(
            chain_id=143, vault=_GOLDEN_VAULT, user=_AGENT,
            token_outs=[_USDC, _WETH], fee_tiers=[3000, 500],
            weights_bps=[6000, 4000], amount_in_wei=10**18,
            amount_out_min=[1000, 1000], deadline=int(_time.time()) + 3600,
        )
        base.update(over)
        return orders.RouteExecution(**base)

    mtx.validate_route_execution(ex())                       # baseline is fine

    for bad, why in [
        (dict(weights_bps=[10_000, 0]), "zero-weight leg"),
        (dict(weights_bps=[6000, 3000]), "weights_bps must sum"),
        (dict(amount_out_min=[0, 1]), "fail-open slippage"),
        (dict(deadline=1), "expired deadline"),
        (dict(user=_ZERO), "zero user"),
        (dict(vault=_ZERO), "zero vault"),
        (dict(amount_in_wei=0), "amount_in_wei"),
        (dict(fee_tiers=[3000]), "same length"),
        (dict(token_outs=[], fee_tiers=[], weights_bps=[], amount_out_min=[]), "non-empty"),
    ]:
        with pytest.raises(ValueError):
            mtx.validate_route_execution(ex(**bad))

    # ...but the commitment itself still mirrors Solidity's permissiveness.
    assert len(mtx.route_commitment(ex(fee_tiers=[3000]), _GOLDEN_ORDER_HASH)) == 32
