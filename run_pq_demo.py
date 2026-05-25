"""Generate a hedged PQ-signed rebalance order from the hardware run.

Reads the QAOA-on-hardware result (outputs/hardware_run*.json) and signs
the resulting rebalance decision with THREE independent signatures:

    ML-DSA-65 (lattice PQ)      — NIST FIPS 204
    SLH-DSA-SHAKE-128s (hash PQ) — NIST FIPS 205
    Ed25519 (classical)          — RFC 8032

An attacker has to break ALL THREE to forge an order. Writes:

    outputs/signed_orders.json     — aggregate (overwritten)
    outputs/audit_log.jsonl        — append-only hash-chained log
    keys/pq.{pub,sec}              — ML-DSA-65 keypair  (sk chmod 600)
    keys/slh.{pub,sec}             — SLH-DSA keypair    (sk chmod 600)
    keys/ed25519.{pub,sec}         — Ed25519 keypair    (sk chmod 600)

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

    ml_kp  = pq.ensure_keypair(KEYS_DIR)
    slh_kp = pq.slh_dsa_ensure_keypair(KEYS_DIR)
    ed_kp  = pq.ed25519_ensure_keypair(KEYS_DIR)
    print(f"Hedged keypairs loaded from {KEYS_DIR}/")
    print(f"  ML-DSA-65   pk={len(ml_kp.pk)}  sk={len(ml_kp.sk)}  (sk chmod 600)")
    print(f"  SLH-DSA-128 pk={len(slh_kp.pk)}    sk={len(slh_kp.sk)}    (sk chmod 600)")
    print(f"  Ed25519     pk={len(ed_kp.pk)}      sk={len(ed_kp.sk)}      (sk chmod 600)")
    print()

    order = orders.RebalanceOrder(
        pools=selected,
        weights=[weight] * len(selected),
        expected_return=abs(optimal_obj),       # objective as a stand-in
        expected_vol=0.15,                       # placeholder for demo
        qpu_job_id=qpu_job_id,
        qaoa_p_optimal=qaoa_p_opt,
    )
    signed = orders.sign_order_hedged(order, ml_kp, slh_kp, ed_kp)
    components = orders.verify_signed_order_components(signed)
    all_ok = orders.verify_signed_order(signed)
    print(f"Order ID:    {order.order_id}")
    print(f"Nonce:       {order.nonce}")
    print(f"Issued at:   {order.issued_at}")
    print(f"Digest:      sha256={signed.message_digest_sha256[:16]}...")
    print(f"Algorithms:  {signed.algorithm}")
    ml_sig_bytes  = len(signed.signature_b64) * 3 // 4
    slh_sig_bytes = len(signed.slh_dsa_signature_b64 or "") * 3 // 4
    ed_sig_bytes  = len(signed.ed25519_signature_b64 or "") * 3 // 4
    print(f"Signatures:  ML-DSA={ml_sig_bytes}B  SLH-DSA={slh_sig_bytes}B  Ed25519={ed_sig_bytes}B")
    print(f"Components:  {components}")
    print(f"Verified:    {all_ok}  (must be True)")
    print()

    # Tamper test — flip one field, every signature must fail
    signed.order.weights[0] += 0.01
    components_t = orders.verify_signed_order_components(signed)
    tampered_ok = orders.verify_signed_order(signed)
    signed.order.weights[0] -= 0.01     # restore for serialisation
    print(f"Tamper test (1 bit on weights[0]):")
    print(f"  Components:  {components_t}")
    print(f"  Verified:    {tampered_ok}  (must be False)")
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
