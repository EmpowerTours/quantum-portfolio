#!/usr/bin/env python3
"""Export a signed order as SP1 guest input (`mldsa_input.json`).

Why this script exists
----------------------
The previous `mldsa_input.json` was produced ad hoc and pinned the ML-DSA key
`8a1b08d1…`, whose secret half was subsequently lost. Everything downstream
inherited that: the Groth16 fixture proves a signature by a retired key, so
`MLDSAAttestation.attest()` reverts `UnknownSigner` against the deployed
`agentPkHash` (`ac0b2aea…`). Because `verifier`, `mldsaProgramVKey` and
`agentPkHash` are all immutable, that mistake is only correctable by
redeploying — which is exactly the class of error worth making unrepresentable.

So this script refuses to emit an input unless the order was signed by the key
that is CURRENTLY on disk, and it re-verifies the signature before writing.
Proving is expensive and remote; discovering a key mismatch afterwards is the
worst possible time.

No secret key material is read, and none is written. The guest input is
(public key, message, signature) — all public — which is what makes it safe to
carry to a rented proving box.

Usage:
    python zk-mldsa/export_mldsa_input.py \
        --order outputs/signed_orders.json --index 0 \
        --out zk-mldsa/mldsa_input.json
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from src import pq_signing as pq  # noqa: E402


def _b64(s: str) -> bytes:
    return base64.b64decode(s, validate=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--order", default="outputs/signed_orders.json",
                    help="signed-order JSON (a single object or a list)")
    ap.add_argument("--index", type=int, default=0,
                    help="which order, if the file holds a list")
    ap.add_argument("--out", default="zk-mldsa/mldsa_input.json")
    ap.add_argument("--pubkey", default="keys/pq.pub",
                    help="the identity the attestation contract will pin")
    args = ap.parse_args()

    order_path = (REPO / args.order) if not Path(args.order).is_absolute() else Path(args.order)
    raw = json.loads(order_path.read_text())
    signed = raw[args.index] if isinstance(raw, list) else raw

    payload = signed["order"]
    pk = _b64(signed["public_key_b64"])
    sig = _b64(signed["signature_b64"])

    # 1. The order must be signed by the identity we will deploy against.
    #    This is the check whose absence produced a fixture for a lost key.
    expected_pk = (REPO / args.pubkey).read_bytes()
    if pk != expected_pk:
        print(f"REFUSING: order was signed by {hashlib.sha256(pk).hexdigest()[:16]}…",
              file=sys.stderr)
        print(f"          but {args.pubkey} is "
              f"{hashlib.sha256(expected_pk).hexdigest()[:16]}…", file=sys.stderr)
        print("          Proving this would yield an attestation that reverts "
              "UnknownSigner on chain.", file=sys.stderr)
        return 1

    # 2. The signature must actually verify, over the exact canonical bytes the
    #    guest will hash. If it does not verify here it cannot verify in the
    #    zkVM either — the guest panics and the proof simply never materialises,
    #    after you have paid for it.
    if not pq.verify(payload, sig, pk):
        print("REFUSING: ML-DSA-65 signature does not verify over the order's "
              "canonical bytes.", file=sys.stderr)
        return 1

    msg = pq.canonical_bytes(payload)

    # 3. The digest the order claims must match the bytes we are exporting.
    claimed = signed.get("message_digest_sha256")
    actual = hashlib.sha256(msg).hexdigest()
    if claimed is not None and claimed != actual:
        print(f"REFUSING: message_digest_sha256 mismatch\n"
              f"          claimed {claimed}\n          actual  {actual}",
              file=sys.stderr)
        return 1

    out_path = (REPO / args.out) if not Path(args.out).is_absolute() else Path(args.out)
    out_path.write_text(json.dumps({
        "pk_hex": pk.hex(),
        "msg_hex": msg.hex(),
        "sig_hex": sig.hex(),
        "digest": actual,
    }, indent=2) + "\n")

    pk_hash = hashlib.sha256(pk).hexdigest()
    # --out may legitimately point outside the repo (a scratch dir, a path on
    # the way to a rented proving box). relative_to() raises ValueError there,
    # which crashed AFTER the file was written — so the export had actually
    # succeeded while the exit code said it failed, and a caller chaining on
    # `&&` would skip the transfer for no reason.
    try:
        shown = out_path.relative_to(REPO)
    except ValueError:
        shown = out_path
    print(f"wrote {shown}")
    print(f"  pkHash (must equal MLDSAAttestation.agentPkHash): 0x{pk_hash}")
    print(f"  orderHash (guest commits this):                   0x{actual}")
    print(f"  msg {len(msg)} bytes, sig {len(sig)} bytes, pk {len(pk)} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
