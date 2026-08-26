"""Reconfiguration statements for `MLDSAAttestationV2`.

The agent key rotates by SIGNING, not by redeploying. `MLDSAAttestationV2`
holds a SET of authorised ML-DSA-65 keys and accepts changes to that set on
proof that a currently authorised key signed a statement naming the change.
This module builds the exact bytes that must be signed.

Why this can reuse the existing proving stack unchanged
-------------------------------------------------------
The SP1 guest (`zk-mldsa/program`) commits `(sha256(msg), sha256(pk))` for an
ARBITRARY message — nothing in it is order-specific. So a reconfiguration
statement is proven by the same guest, the same vkey and the same Groth16
verifier as an order. Rotation costs no change to the prover, no new circuit,
and no new deployment of anything except the attestation contract itself.

Layout (137 bytes, mirrored by `MLDSAAttestationV2.statementBytes`)
--------------------------------------------------------------------
    b"MLDSA-ATTEST-V2-AUTH"   20  domain tag
    action                     1  1=ADD, 2=REVOKE, 3=VETO, 4=SET_GUARDIAN
    chain_id                  32  big-endian uint256
    contract                  20  the attestation contract
    nonce                     32  big-endian uint256, must equal rotationNonce
    subject                   32  the pk hash being added/revoked/vetoed, or the
                                  left-padded guardian address for SET_GUARDIAN

Fixed-width and non-JSON on purpose. The contract recomputes these bytes from
its own state and the caller's arguments and compares hashes — there is no
parser on the chain side and therefore no parser to attack. The domain tag also
guarantees a statement can never be confused with an order: canonical orders are
compact JSON and begin with `{`, statements begin with `M`.

Every field that is not the action or the subject is a replay guard: `chain_id`
and `contract` stop a testnet statement from acting on mainnet, and `nonce`
makes each statement single-use.

CLI
---
    python -m src.pq_rotation --action add \\
        --subject 0x<sha256 of the NEW keys/pq.pub> \\
        --contract 0x<MLDSAAttestationV2> --chain-id 143 --nonce 0 \\
        --keys keys/ --out zk-mldsa/mldsa_input.json

Writes an SP1 guest input in the same shape as
`zk-mldsa/export_mldsa_input.py`, so the rest of the proving pipeline is
untouched. Prove it, then submit the proof to `rotateAdd`/`rotateRevoke`/
`vetoRecovery`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

DOMAIN = b"MLDSA-ATTEST-V2-AUTH"
assert len(DOMAIN) == 20, "domain tag must be 20 bytes to match bytes20 on chain"

ACTION_ADD = 1
ACTION_REVOKE = 2
ACTION_VETO = 3
ACTION_SET_GUARDIAN = 4

ACTIONS = {
    "add": ACTION_ADD,
    "revoke": ACTION_REVOKE,
    "veto": ACTION_VETO,
    "set-guardian": ACTION_SET_GUARDIAN,
}

STATEMENT_LEN = 137


def _as32(value: bytes | str) -> bytes:
    """Accept a 0x-hex string or raw bytes; return exactly 32 bytes."""
    if isinstance(value, str):
        v = value[2:] if value.startswith(("0x", "0X")) else value
        raw = bytes.fromhex(v)
    else:
        raw = bytes(value)
    if len(raw) != 32:
        raise ValueError(f"expected 32 bytes, got {len(raw)}")
    return raw


def _address(value: str) -> bytes:
    v = value[2:] if value.startswith(("0x", "0X")) else value
    raw = bytes.fromhex(v)
    if len(raw) != 20:
        raise ValueError(f"expected a 20-byte address, got {len(raw)}")
    return raw


def subject_for(action: int, value: bytes | str) -> bytes:
    """The 32-byte subject field for `action`.

    For every action but `set-guardian` the subject is a key fingerprint and is
    already 32 bytes. `set-guardian` names an ADDRESS, which the contract writes
    as `bytes32(uint256(uint160(addr)))` — left-padded with twelve zero bytes.
    Accepting either form here, and checking the padding, means an operator
    cannot silently sign a statement for a different guardian by pasting the
    wrong width.
    """
    if action != ACTION_SET_GUARDIAN:
        return _as32(value)
    if isinstance(value, str):
        raw = bytes.fromhex(value[2:] if value.startswith(("0x", "0X")) else value)
    else:
        raw = bytes(value)
    if len(raw) == 20:
        return b"\x00" * 12 + raw
    if len(raw) == 32:
        if raw[:12] != b"\x00" * 12:
            raise ValueError("set-guardian subject must be a left-padded 20-byte address")
        return raw
    raise ValueError(f"expected a 20- or 32-byte guardian address, got {len(raw)}")


def statement_bytes(
    action: int,
    subject: bytes | str,
    nonce: int,
    chain_id: int,
    contract: str,
) -> bytes:
    """The exact bytes the agent must ML-DSA-sign.

    Byte-for-byte identical to `MLDSAAttestationV2.statementBytes`; the parity
    goldens live in `tests/test_pq_rotation.py` and
    `zk-mldsa/contracts/test/MLDSAAttestationV2Parity.t.sol`. If those two
    disagree, one side has drifted and every rotation signed against the drifted
    side is unusable — do not "fix" a golden, fix the implementation.
    """
    if action not in (ACTION_ADD, ACTION_REVOKE, ACTION_VETO, ACTION_SET_GUARDIAN):
        raise ValueError(f"unknown action {action}")
    if nonce < 0 or nonce >= 2**256:
        raise ValueError("nonce out of range")
    if chain_id < 0 or chain_id >= 2**256:
        raise ValueError("chain_id out of range")
    out = (
        DOMAIN
        + bytes([action])
        + chain_id.to_bytes(32, "big")
        + _address(contract)
        + nonce.to_bytes(32, "big")
        + subject_for(action, subject)
    )
    assert len(out) == STATEMENT_LEN
    return out


def statement_hash(
    action: int,
    subject: bytes | str,
    nonce: int,
    chain_id: int,
    contract: str,
) -> bytes:
    """sha256 of `statement_bytes` — what the SP1 guest commits as `orderHash`."""
    return hashlib.sha256(statement_bytes(action, subject, nonce, chain_id, contract)).digest()


def sign_statement(
    action: int,
    subject: bytes | str,
    nonce: int,
    chain_id: int,
    contract: str,
    sk: bytes,
    pk: bytes,
) -> dict[str, Any]:
    """Sign a statement and return the SP1 guest input.

    Re-verifies before returning. Proving is expensive and remote; a signature
    that does not verify here cannot verify in the zkVM either — the guest
    panics and the proof never materialises, after you have paid for it. That
    failure mode is why `zk-mldsa/export_mldsa_input.py` checks too.
    """
    from src import pq_signing as pq

    msg = statement_bytes(action, subject, nonce, chain_id, contract)
    sig = pq.sign_bytes(msg, sk)
    if not pq.verify_bytes(msg, sig, pk):
        raise RuntimeError("ML-DSA-65 signature does not verify over the statement bytes")
    return {
        "pk_hex": pk.hex(),
        "msg_hex": msg.hex(),
        "sig_hex": sig.hex(),
        "digest": hashlib.sha256(msg).hexdigest(),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--action", required=True, choices=sorted(ACTIONS),
                    help="add / revoke / veto / set-guardian")
    ap.add_argument("--subject", required=True,
                    help="0x-hex sha256 of the ML-DSA public key being acted on; "
                         "for set-guardian, the 20-byte guardian ADDRESS instead")
    ap.add_argument("--contract", required=True, help="MLDSAAttestationV2 address")
    ap.add_argument("--chain-id", type=int, default=143, help="143 = Monad mainnet")
    ap.add_argument("--nonce", type=int, required=True,
                    help="must equal the contract's current rotationNonce()")
    ap.add_argument("--keys", default="keys/",
                    help="directory holding the CURRENTLY AUTHORISED keypair")
    ap.add_argument("--out", default="zk-mldsa/mldsa_input.json")
    args = ap.parse_args(argv)

    repo = Path(__file__).resolve().parent.parent
    sys.path.insert(0, str(repo))
    from src import pq_signing as pq

    action = ACTIONS[args.action]

    # The signer must be a key the contract ALREADY authorises. Signing with a
    # key the contract does not know produces a proof that reverts
    # UnknownSigner — which is the same wasted-proof failure that lost a week
    # in 2026-07.
    kp = pq.ensure_keypair(Path(args.keys))
    signer_hash = hashlib.sha256(kp.pk).hexdigest()

    inp = sign_statement(action, args.subject, args.nonce, args.chain_id,
                         args.contract, kp.sk, kp.pk)

    out_path = Path(args.out)
    if not out_path.is_absolute():
        out_path = repo / out_path
    out_path.write_text(json.dumps(inp, indent=2) + "\n")

    print(f"wrote {out_path}")
    print(f"  action:   {args.action} (id {action})")
    print(f"  subject:  {args.subject}")
    print(f"  signer:   0x{signer_hash}")
    print(f"           ^ must satisfy isAgentPk() on {args.contract}; check with")
    print(f"             cast call {args.contract} 'isAgentPk(bytes32)(bool)' 0x{signer_hash}")
    print(f"  nonce:    {args.nonce}")
    print(f"           ^ must equal rotationNonce(); check with")
    print(f"             cast call {args.contract} 'rotationNonce()(uint256)'")
    print(f"  statement sha256 (guest commits this): 0x{inp['digest']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
