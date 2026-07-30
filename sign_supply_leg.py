#!/usr/bin/env python3
"""Sign the yield-deposit leg as its own PQ-signed order.

Why this is a SEPARATE order from the routing leg
-------------------------------------------------
AuditAnchorV2 stores exactly one execution commitment per (user, orderHash)
and refuses to re-anchor a hash. The routing vault and the Morpho adapter both
read that same slot — `ANCHOR.execCommitmentOf(msg.sender, orderHash)` — and
each expects to find ITS OWN commitment there. So the two legs cannot share an
orderHash.

That is a direct consequence of the M-6 fix. V1's `lastHash[anchorer]` was a
single value both executors compared against, which is exactly why it was
unsafe: it authorised *any* execution by that anchorer rather than one specific
one. Binding the anchor to a concrete commitment is what closed that hole, and
the cost is that each executor needs its own anchored order.

`max_assets` is a ceiling rather than an exact amount because the yield leg
chains off a swap whose output is not known at signing time. The signature
authorises the range (0, max], and the adapter enforces `assets <= maxAssets`.

Usage:
    python sign_supply_leg.py --max-assets 2123
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from src import monad_tx, orders, pq_signing as pq

# Monad mainnet, verified on-chain.
CHAIN_ID = 143
USDC = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"
WBTC = "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c"
ORACLE = "0xff07261c87763cc5693ab78746d0b6735Ec626F5"
IRM = "0x09475a3D6eA8c314c592b1a3799bDE044E2F400F"
LLTV = 860000000000000000

KEYS_DIR = Path("keys")
OUT = Path("outputs/mainnet_supply_order.json")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--adapter", required=True)
    ap.add_argument("--user", required=True)
    ap.add_argument("--max-assets", type=int, required=True,
                    help="ceiling in loan-token base units (USDC has 6 dp)")
    args = ap.parse_args()

    if args.max_assets <= 0:
        raise SystemExit("max_assets must be positive")

    # Carry the SAME quantum decision forward — this leg deploys the proceeds
    # of the routing leg, so it inherits its provenance.
    route_order = orders.load_signed_orders()[0].order

    ml = pq.ensure_keypair(KEYS_DIR)
    slh = pq.slh_dsa_ensure_keypair(KEYS_DIR)
    ed = pq.ed25519_ensure_keypair(KEYS_DIR)

    ex = orders.SupplyExecution(
        chain_id=CHAIN_ID,
        adapter=args.adapter,
        user=args.user,
        loan_token=USDC,
        collateral_token=WBTC,
        oracle=ORACLE,
        irm=IRM,
        lltv=LLTV,
        max_assets=args.max_assets,
    )
    order = orders.RebalanceOrder(
        pools=route_order.pools,
        weights=route_order.weights,
        expected_return=route_order.expected_return,
        expected_vol=route_order.expected_vol,
        qpu_job_id=route_order.qpu_job_id,
        qaoa_p_optimal=route_order.qaoa_p_optimal,
        execution=ex,
    )
    signed = orders.sign_order_hedged(order, ml, slh, ed)

    trusted = orders.TrustedKeys(ml_dsa=ml.pk, slh_dsa=slh.pk, ed25519=ed.pk)
    if not orders.verify_signed_order(signed, trusted=trusted):
        raise SystemExit("refusing to emit: the order does not verify")

    order_hash = monad_tx.order_sha256(signed)
    commitment = monad_tx.supply_commitment(ex, order_hash)

    OUT.write_text(json.dumps([signed.to_dict()], indent=2) + "\n")
    orders.append_audit(signed, trusted=trusted)

    print(f"wrote {OUT}")
    print(f"  orderHash       0x{order_hash.hex()}")
    print(f"  supplyCommit    0x{commitment.hex()}")
    print(f"  adapter         {ex.adapter}")
    print(f"  maxAssets       {ex.max_assets}")
    print(f"  qpu_job_id      {order.qpu_job_id}  (inherited from the routing leg)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
