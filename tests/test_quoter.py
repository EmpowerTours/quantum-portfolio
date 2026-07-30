"""Tests for the live QuoterV2 client.

The network is stubbed throughout — these assert the encoding and, more
importantly, that every failure path REFUSES rather than falling back to a
guessed rate. A quoter that returns a plausible number when the node is down is
worse than one that raises, because the resulting floor gets PQ-signed and
anchored on chain.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import quoter


WMON = "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A"
USDC = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"

# Verified byte-for-byte against:
#   cast calldata 'quoteExactInputSingle((address,address,uint256,uint24,uint160))' \
#     '(0x3bd3...433A,0x7547...b603,100000000000000000,3000,0)'
GOLDEN_CALLDATA = (
    "0xc6a5026a"
    "0000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a"
    "000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb603"
    "000000000000000000000000000000000000000000000000016345785d8a0000"
    "0000000000000000000000000000000000000000000000000000000000000bb8"
    "0000000000000000000000000000000000000000000000000000000000000000"
)


def _ret(amount_out: int, words: int = 4) -> bytes:
    """A well-formed QuoterV2 return: 4 words, amountOut first."""
    return amount_out.to_bytes(32, "big") + bytes(32 * (words - 1))


def _stub(monkeypatch, ret: bytes, capture: dict | None = None):
    def fake(rpc_url, to, data, timeout):
        if capture is not None:
            capture["rpc_url"] = rpc_url
            capture["to"] = to
            capture["data"] = data
        return ret
    monkeypatch.setattr(quoter, "_rpc_call", fake)


def test_calldata_matches_the_cast_golden(monkeypatch):
    cap: dict = {}
    _stub(monkeypatch, _ret(2132), cap)
    quoter.quote_exact_input_single(WMON, USDC, 10**17, 3000)
    assert "0x" + cap["data"].hex() == GOLDEN_CALLDATA


def test_returns_the_first_word_as_amount_out(monkeypatch):
    _stub(monkeypatch, _ret(2132))
    assert quoter.quote_exact_input_single(WMON, USDC, 10**17, 3000) == 2132


def test_targets_the_verified_quoter_by_default(monkeypatch):
    cap: dict = {}
    _stub(monkeypatch, _ret(1), cap)
    quoter.quote_exact_input_single(WMON, USDC, 1, 3000)
    assert cap["to"] == quoter.QUOTER_V2_MAINNET


def test_zero_amount_out_raises_rather_than_returning_zero(monkeypatch):
    """A zero quote would drive amountOutMin to 0 — the fail-open floor the
    vault rejects on chain (L-2). It must never reach the signer."""
    _stub(monkeypatch, _ret(0))
    with pytest.raises(quoter.QuoteError, match="no usable liquidity"):
        quoter.quote_exact_input_single(WMON, USDC, 10**17, 3000)


def test_short_return_is_rejected(monkeypatch):
    """A non-QuoterV2 address may return something decodable-looking."""
    _stub(monkeypatch, bytes(64))
    with pytest.raises(quoter.QuoteError, match="expected >= 128"):
        quoter.quote_exact_input_single(WMON, USDC, 10**17, 3000)


def test_network_failure_propagates_as_quote_error(monkeypatch):
    def boom(*a, **k):
        raise OSError("connection refused")
    monkeypatch.setattr(quoter.urllib.request, "urlopen", boom)
    with pytest.raises(quoter.QuoteError, match="quote RPC call failed"):
        quoter.quote_exact_input_single(WMON, USDC, 10**17, 3000)


def test_rpc_error_object_propagates_as_quote_error(monkeypatch):
    class FakeResp:
        def read(self):
            return b'{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"exec reverted"}}'
        def __enter__(self):
            return self
        def __exit__(self, *a):
            return False
    monkeypatch.setattr(quoter.urllib.request, "urlopen", lambda *a, **k: FakeResp())
    with pytest.raises(quoter.QuoteError, match="reverted on-chain"):
        quoter.quote_exact_input_single(WMON, USDC, 10**17, 3000)


@pytest.mark.parametrize("fee", [100, 0, 2500, 10001])
def test_rejects_fee_tiers_the_vault_does_not_allowlist(fee):
    """Tier 100 is the dust pool H-3 exists to exclude; quoting it would
    produce a floor for a route the vault will refuse anyway."""
    with pytest.raises(ValueError, match="fee must be one of"):
        quoter.quote_exact_input_single(WMON, USDC, 10**17, fee)


@pytest.mark.parametrize("amount", [0, -1])
def test_rejects_non_positive_amount(amount):
    with pytest.raises(ValueError, match="must be positive"):
        quoter.quote_exact_input_single(WMON, USDC, amount, 3000)


@pytest.mark.parametrize("bad", ["0x1234", "not-an-address", "", "0x" + "0" * 41])
def test_rejects_malformed_addresses(bad):
    with pytest.raises(ValueError, match="not a 20-byte hex address"):
        quoter.quote_exact_input_single(bad, USDC, 10**17, 3000)


def test_bool_is_not_accepted_as_a_uint():
    with pytest.raises(TypeError):
        quoter._word(True)
