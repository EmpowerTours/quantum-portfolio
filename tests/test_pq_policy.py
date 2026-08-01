"""Negative tests for the PQ verification POLICY flags.

These pass `require_execution=False` deliberately: they isolate SIGNATURE and
KEY policy. The default is `require_execution=None` -> True for schema v2, so
a v2 order with `execution=None` is rejected outright — verified separately in
test_v2_order_without_execution_is_rejected_by_default below.

An external cryptographic review observed that the two highest-severity fixes
in this layer had no regression test at all:

  M-1  `trusted=` pins verification to keys WE hold, so an artefact signed with
       an attacker's own three keypairs is rejected. Every existing test either
       omitted `trusted` or passed dummy key bytes with `require_hedged=False`.
  Z-2  `require_hedged=True` rejects an order with a signature leg stripped,
       closing the downgrade from three algorithms to one.

Both were described at length in docstrings and neither was asserted. These
tests assert the rejection, not the acceptance.
"""
from __future__ import annotations

import base64
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import orders, pq_signing as pq


@pytest.fixture(scope="module")
def agent_keys():
    return (pq.generate_keypair(), pq.slh_dsa_generate_keypair(),
            pq.ed25519_generate_keypair())


@pytest.fixture(scope="module")
def attacker_keys():
    return (pq.generate_keypair(), pq.slh_dsa_generate_keypair(),
            pq.ed25519_generate_keypair())


def _order():
    return orders.RebalanceOrder(
        pools=["A", "B"], weights=[0.5, 0.5],
        expected_return=0.1, expected_vol=0.02,
    )


def _sign(keys):
    ml, slh, ed = keys
    return orders.sign_order_hedged(_order(), ml, slh, ed, seen_nonces=set())


def _trusted(keys):
    ml, slh, ed = keys
    return orders.TrustedKeys(ml_dsa=ml.pk, slh_dsa=slh.pk, ed25519=ed.pk)


# --- M-1: pinning rejects a self-consistent forgery -----------------------

def test_M1_selfconsistent_forgery_is_rejected_when_pinned(agent_keys, attacker_keys):
    """The attacker signs an order of their own invention with their OWN three
    keypairs. It is internally perfect. Pinning to the agent's keys is the only
    thing that rejects it."""
    forged = _sign(attacker_keys)
    assert orders.verify_signed_order(forged, trusted=None, seen_nonces=set(), require_execution=False) is True, \
        "precondition: the forgery is self-consistent"
    assert orders.verify_signed_order(
        forged, trusted=_trusted(agent_keys), seen_nonces=set(),
        require_execution=False) is False, \
        "M-1: pinning MUST reject an order signed by keys we do not hold"


def test_M1_genuine_order_passes_pinning(agent_keys):
    signed = _sign(agent_keys)
    assert orders.verify_signed_order(
        signed, trusted=_trusted(agent_keys), seen_nonces=set(),
        require_execution=False) is True


@pytest.mark.parametrize("swap", ["ml_dsa", "slh_dsa", "ed25519"])
def test_M1_one_wrong_pinned_key_is_enough_to_reject(agent_keys, attacker_keys, swap):
    """A partially-correct pin must still fail — otherwise an attacker who
    compromises one key downgrades the hedge."""
    signed = _sign(agent_keys)
    ml, slh, ed = agent_keys
    aml, aslh, aed = attacker_keys
    t = orders.TrustedKeys(
        ml_dsa=aml.pk if swap == "ml_dsa" else ml.pk,
        slh_dsa=aslh.pk if swap == "slh_dsa" else slh.pk,
        ed25519=aed.pk if swap == "ed25519" else ed.pk,
    )
    assert orders.verify_signed_order(signed, trusted=t, seen_nonces=set(), require_execution=False) is False, \
        f"a wrong pinned {swap} key must reject"


# --- Z-2: require_hedged blocks the downgrade ----------------------------

@pytest.mark.parametrize("strip", [
    ("slh_dsa_signature_b64", "slh_dsa_public_key_b64"),
    ("ed25519_signature_b64", "ed25519_public_key_b64"),
])
def test_Z2_stripping_a_leg_is_rejected_when_hedging_required(agent_keys, strip):
    signed = _sign(agent_keys)
    for field in strip:
        object.__setattr__(signed, field, None) if hasattr(signed, "__dataclass_fields__") \
            else setattr(signed, field, None)
    t = _trusted(agent_keys)
    assert orders.verify_signed_order(
        signed, trusted=t, require_hedged=True, seen_nonces=set(),
        require_execution=False) is False, \
        "Z-2: a stripped order must NOT verify when hedging is required"
    assert orders.verify_signed_order(
        signed, trusted=t, require_hedged=False, seen_nonces=set(),
        require_execution=False) is True, \
        "precondition: it verifies only because the policy was relaxed"


@pytest.mark.parametrize("leg", [
    "signature_b64", "slh_dsa_signature_b64", "ed25519_signature_b64",
])
def test_corrupting_any_single_leg_fails_the_whole_order(agent_keys, leg):
    """The combiner must be AND: one bad leg fails everything."""
    signed = _sign(agent_keys)
    raw = bytearray(base64.b64decode(getattr(signed, leg)))
    raw[0] ^= 0xFF
    setattr(signed, leg, base64.b64encode(bytes(raw)).decode())
    assert orders.verify_signed_order(
        signed, trusted=_trusted(agent_keys), seen_nonces=set(),
        require_execution=False) is False


# --- L-4: canonicalisation must stay injective ---------------------------

@pytest.mark.parametrize("payload", [
    {1: "x"}, {True: 1}, {None: 1}, {1.0: "y"}, {(1, 2): "z"},
])
def test_L4_non_string_dict_keys_are_rejected(payload):
    """json.dumps stringifies these, so {1:'x'} and {'1':'x'} would sign
    identically — distinct payloads, one signature, one orderHash."""
    with pytest.raises(ValueError, match="non-string dict key"):
        pq.canonical_bytes(payload)


def test_L4_the_specific_collision_is_now_impossible():
    a = pq.canonical_bytes({"1": "x", "2": "y"})
    with pytest.raises(ValueError):
        pq.canonical_bytes({1: "x", 2: "y"})
    assert a == b'{"1":"x","2":"y"}'


def test_v2_order_without_execution_is_rejected_by_default(agent_keys):
    """The default policy refuses a schema-v2 order carrying no execution
    block, so a signature cannot authorise an unspecified trade."""
    signed = _sign(agent_keys)
    assert signed.order.schema_version >= 2 and signed.order.execution is None
    assert orders.verify_signed_order(
        signed, trusted=_trusted(agent_keys), seen_nonces=set()) is False, \
        "default require_execution must reject a v2 order with no execution block"
