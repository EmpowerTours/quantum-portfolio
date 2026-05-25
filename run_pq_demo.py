"""Generate a real PQ-signed rebalance order from the hardware run.

Reads the QAOA-on-hardware result (outputs/hardware_run.json) and signs the
resulting rebalance decision with ML-DSA-65. Writes:

    outputs/signed_orders.json   — aggregate (overwritten)
    outputs/audit_log.jsonl      — append-only log
    keys/pq.pub + keys/pq.sec    — keypair (created if missing, sk chmod 600)

Run:
    python run_pq_demo.py
"""
from __future__ import annotations

import json
from pathlib import Path

from src import orders, pq_signing as pq

HARDWARE_RUN_DEFI   = Path("outputs/hardware_run_defi.json")
HARDWARE_RUN_STOCKS = Path("outputs/hardware_run.json")
KEYS_DIR            = Path("keys")


def _pick_hardware_run() -> Path:
    """Prefer the DeFi-universe run when both are present (it matches the
    project's pitch); fall back to the cached stocks run."""
    if HARDWARE_RUN_DEFI.exists():
        return HARDWARE_RUN_DEFI
    if HARDWARE_RUN_STOCKS.exists():
        return HARDWARE_RUN_STOCKS
    raise SystemExit(
        "no hardware-run artefact found — run `python run_hardware.py "
        "--universe defi` first."
    )


def main() -> None:
    run_path = _pick_hardware_run()
    print(f"Using hardware artefact: {run_path}")
    hw = json.loads(run_path.read_text())
    tickers       = hw["tickers"]
    optimal_idx   = hw["optimal"]["selection"]
    optimal_obj   = hw["optimal"]["objective"]
    mitigated     = next((r for r in hw["results"]
                          if "mitigated" in r["method"]), None)
    qpu_job_id    = mitigated["job_id"] if mitigated else None
    qaoa_p_opt    = mitigated["p_optimal"] if mitigated else None

    selected = [tickers[i] for i in optimal_idx]
    weight = 1.0 / len(selected)
    print(f"Hardware backend: {hw['backend']}")
    print(f"Optimal selection: {selected}")
    print(f"QPU job (mitigated): {qpu_job_id}")
    print()

    kp = pq.ensure_keypair(KEYS_DIR)
    print(f"ML-DSA-65 keypair loaded from {KEYS_DIR}/")
    print(f"  public key:  {len(kp.pk)} bytes")
    print(f"  secret key:  {len(kp.sk)} bytes  (chmod 600)")
    print()

    order = orders.RebalanceOrder(
        pools=selected,
        weights=[weight] * len(selected),
        expected_return=abs(optimal_obj),       # objective as a stand-in
        expected_vol=0.15,                       # placeholder for demo
        qpu_job_id=qpu_job_id,
        qaoa_p_optimal=qaoa_p_opt,
    )
    signed = orders.sign_order(order, kp)
    ok = orders.verify_signed_order(signed)
    print(f"Order ID:    {order.order_id}")
    print(f"Nonce:       {order.nonce}")
    print(f"Issued at:   {order.issued_at}")
    print(f"Digest:      sha256={signed.message_digest_sha256[:16]}...")
    print(f"Signature:   {len(signed.signature_b64)} chars (b64)  "
          f"≈ {int(len(signed.signature_b64) * 3 / 4)} raw bytes")
    print(f"Verified:    {ok}")
    print()

    # tamper-test
    tampered = orders.SignedOrder(
        order=orders.RebalanceOrder(**{**order.to_dict(), "pools": ["EVIL"]}),
        algorithm=signed.algorithm,
        public_key_b64=signed.public_key_b64,
        signature_b64=signed.signature_b64,
        message_digest_sha256=signed.message_digest_sha256,
    )
    tampered_ok = orders.verify_signed_order(tampered)
    print(f"Tamper test: swapped pools → verify={tampered_ok} "
          f"(must be False)")
    print()

    orders.append_audit(signed)
    orders.save_signed_orders([signed])
    print(f"Wrote {orders.SIGNED_ORDERS_PATH} and appended to "
          f"{orders.AUDIT_LOG_PATH}")

    # ---- Unsigned Monad TX carrying the signed order ----
    from src import monad_tx
    AGENT_SELF_ADDR = "0x1111111111111111111111111111111111111111"  # placeholder
    tx = monad_tx.build_unsigned_tx(signed, to_address=AGENT_SELF_ADDR, nonce=0)
    tx_path = Path("outputs/unsigned_monad_tx.json")
    tx_path.write_text(json.dumps(tx.to_dict(), indent=2))
    print()
    print(f"Built unsigned Monad TX → {tx_path}")
    print(f"  chainId={tx.chainId}  to={tx.to}  calldata={len(tx.data)//2 - 1} bytes")
    print("  (sign with a wallet to broadcast — execution intentionally")
    print("   separated from PQ-signed authorisation; see SECURITY.md)")


if __name__ == "__main__":
    main()
