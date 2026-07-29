"""Generate a hedged PQ-signed rebalance order from the hardware run.

Reads the QAOA-on-hardware result (outputs/hardware_run*.json) and signs
the resulting rebalance decision with THREE independent signatures:

    ML-DSA-65 (lattice PQ)            — NIST FIPS 204
    SLH-DSA-SHAKE-256s (hash PQ, L5)  — NIST FIPS 205
    Ed25519 (classical)               — RFC 8032

An attacker has to break ALL THREE to forge an order. Writes:

    outputs/signed_orders.json     — aggregate (overwritten)
    outputs/audit_log.jsonl        — append-only hash-chained log
    outputs/unsigned_monad_tx.json — wallet-ready EIP-1559 TX
                                     (self-transfer with full signed-order payload)
    outputs/unsigned_anchor_tx.json — wallet-ready anchor TX
                                     (calls deployed AuditAnchor.anchor)
    keys/pq.{pub,sec}              — ML-DSA-65 keypair  (sk chmod 600)
    keys/slh.{pub,sec}             — SLH-DSA keypair    (sk chmod 600)
    keys/ed25519.{pub,sec}         — Ed25519 keypair    (sk chmod 600)

Network: requires DeFiLlama (or yfinance) reachability so the signed
order's expected_return and expected_vol are real numbers, not
placeholders — derived from the same market-data pipeline the QPU run
optimised over. Yields drift between QPU run time and signing time;
`issued_at` records when the metrics were evaluated.

Run:
    python run_pq_demo.py
"""
from __future__ import annotations

import importlib
import json
import os
import time
from dataclasses import replace
from pathlib import Path

from src import orders, pq_signing as pq

# --- Monad mainnet (chainId 143) constants, on-chain verified 2026-07-28 ---
MONAD_MAINNET_CHAIN_ID = 143
USDC_MAINNET = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"
USDC_FEE_TIER = 3000          # the only genuinely liquid WMON/USDC pool

# Reference rate from the live WMON/USDC 0.3% pool (fork-measured 2026-07-28):
# 0.1 MON -> 2118 USDC micro-units. This is a REFERENCE for the demo only; a
# production order must derive amountOutMin from a live quote at signing time,
# because the floor is now the entire MEV defence (contract RT04c).
REFERENCE_USDC_PER_MON_MICRO = 21180


def _build_route_execution(amount_in_wei: int,
                           slippage_bps: int,
                           valid_for_s: int) -> orders.RouteExecution:
    """Construct the schema-v2 execution block the order will authorise.

    Single leg into USDC because that is the only token with real depth on
    Monad mainnet — the sibling WMON/USDC pools hold 0.19 and 2.93 USDC
    against 447k in the 0.3% pool, which is why fee tiers are allowlisted
    on-chain rather than trusted from calldata (contract H-3).
    """
    vault = os.environ.get("UNISWAP_ROUTING_VAULT", "0x" + "0" * 40)
    user = os.environ.get("AGENT_ADDRESS", "0x" + "0" * 40)
    if vault == "0x" + "0" * 40 or user == "0x" + "0" * 40:
        print("NOTE: UNISWAP_ROUTING_VAULT / AGENT_ADDRESS unset — the execution")
        print("      block is structurally valid but points at the zero address.")
        print("      Set both once AuditAnchorV2 + the V2 vault are deployed.")

    expected_out = amount_in_wei * REFERENCE_USDC_PER_MON_MICRO // 10**18
    floor = expected_out * (10_000 - slippage_bps) // 10_000
    return orders.RouteExecution(
        chain_id=MONAD_MAINNET_CHAIN_ID,
        vault=vault,
        user=user,
        token_outs=[USDC_MAINNET],
        fee_tiers=[USDC_FEE_TIER],
        weights_bps=[10_000],
        amount_in_wei=amount_in_wei,
        amount_out_min=[max(floor, 1)],
        deadline=int(time.time()) + valid_for_s,
    )

HARDWARE_RUN_DEFI   = Path("outputs/hardware_run_defi.json")
HARDWARE_RUN_STOCKS = Path("outputs/hardware_run.json")
KEYS_DIR            = Path("keys")

# Deployed on Monad testnet (chainId 10143), both Monadscan-verified.
# The full quantum->PQ->anchor->swap->yield->ZK-attestation loop is LIVE on Monad mainnet (chainId 143), all contracts Monadscan-verified.
AUDIT_ANCHOR_TESTNET = "0x0e649C383CFA6be1998445D0A7a8E1cc7540D239"
ALLOC_VAULT_TESTNET  = "0xC39e298ce89cDfc934c697c9Fe0CC4BAA80B87f5"

# Demo allocation amount (0.01 MON). The vault's `withdraw` lets the
# same wallet pull the deposit back, so this is reversible test value.
DEMO_ALLOC_WEI = 10**16

# Agent's broadcast wallet. The same key signs the on-chain ECDSA TX
# (intent → execution separation, see SECURITY.md). Public address only,
# the corresponding private key never appears in source.
AGENT_WALLET_ADDR = "0xe67e13D545C76C2b4e28DFE27Ad827E1FC18e8D9"

RISK_FACTOR = 0.5


def _pick_hardware_run() -> tuple[Path, str]:
    """Prefer the DeFi-universe run when both are present (it matches the
    project's pitch); fall back to the cached stocks run."""
    if HARDWARE_RUN_DEFI.exists():
        return HARDWARE_RUN_DEFI, "defi"
    if HARDWARE_RUN_STOCKS.exists():
        return HARDWARE_RUN_STOCKS, "stocks"
    raise SystemExit(
        "no hardware-run artefact found — run `python run_hardware.py "
        "--universe defi` first."
    )


def _real_portfolio_metrics(universe: str, artefact_tickers: list[str],
                            selection_idx: list[int], budget: int
                            ) -> dict[str, float | str]:
    """Re-fetch live market data via the same pipeline the QPU run used
    and compute the actual expected return + volatility of the QPU's
    selected portfolio under current conditions.

    Why re-fetch instead of caching mu/sigma in the artefact:
      * the existing hardware_run_*.json predates this layer; re-running
        run_hardware.py to add mu/sigma costs paid QPU time
      * yields drift, so a signed order's expected_return reflects market
        state at signing time, not at QPU-run time — that is the honest
        framing for a long-lived audit artefact

    Fails loudly on a network error so we never sign a placeholder value.
    """
    from src.problem import build_problem
    from src import solvers

    if universe == "defi":
        from src.defi_data import get_defi_market_data
        market = get_defi_market_data(days=365)
    else:
        from src.data import get_market_data
        market = get_market_data(artefact_tickers, period="2y")

    fresh_tickers = list(market.tickers)
    mapped_selection: list[int] = []
    for i in selection_idx:
        name = artefact_tickers[i]
        if name not in fresh_tickers:
            raise RuntimeError(
                f"asset {name!r} from hardware artefact no longer present "
                f"in fresh market data — cannot compute portfolio metrics "
                f"for the signed order. Re-run `run_hardware.py` to refresh."
            )
        mapped_selection.append(fresh_tickers.index(name))

    problem = build_problem(market, budget=budget, risk_factor=RISK_FACTOR)
    m = solvers.portfolio_metrics(problem, market.mu, market.sigma, mapped_selection)
    m["data_source"] = market.source
    return m


def main() -> None:
    run_path, universe = _pick_hardware_run()
    print(f"Using hardware artefact: {run_path}  (universe: {universe})")
    hw = json.loads(run_path.read_text())
    tickers     = hw["tickers"]
    budget      = int(hw.get("budget", 3))
    optimal_idx = hw["optimal"]["selection"]
    mitigated   = next((r for r in hw["results"]
                        if "mitigated" in r["method"]), None)
    qpu_job_id  = mitigated["job_id"] if mitigated else None
    qaoa_p_opt  = mitigated["p_optimal"] if mitigated else None

    selected = [tickers[i] for i in optimal_idx]
    weight = 1.0 / len(selected)
    print(f"Hardware backend:   {hw['backend']}")
    print(f"Optimal selection:  {selected}")
    print(f"QPU job (mitigated): {qpu_job_id}")
    print()

    print(f"Re-deriving expected return + volatility from live {universe} data...")
    metrics = _real_portfolio_metrics(universe, tickers, optimal_idx, budget=budget)
    print(f"  data source:     {metrics['data_source']}")
    print(f"  expected_return: {metrics['return']:+.4f}  ({float(metrics['return']):.2%})")
    print(f"  expected_vol:    {float(metrics['volatility']):.4f}  ({float(metrics['volatility']):.2%})")
    print(f"  sharpe:          {float(metrics['sharpe']):.3f}")
    print()

    # Creating an identity is opt-in: set QUANTUM_ALLOW_NEW_IDENTITY=1 for a
    # genuine first run. Without it a missing keys/ raises instead of silently
    # minting a new agent — the failure mode that lost the 2026-07-12 key.
    _new_ok = os.environ.get("QUANTUM_ALLOW_NEW_IDENTITY") == "1"
    ml_kp  = pq.ensure_keypair(KEYS_DIR, allow_create=_new_ok)
    slh_kp = pq.slh_dsa_ensure_keypair(KEYS_DIR, allow_create=_new_ok)
    ed_kp  = pq.ed25519_ensure_keypair(KEYS_DIR, allow_create=_new_ok)
    print(f"Hedged keypairs loaded from {KEYS_DIR}/")
    print(f"  ML-DSA-65    pk={len(ml_kp.pk)}  sk={len(ml_kp.sk)}  (sk chmod 600)")
    print(f"  SLH-DSA-256s pk={len(slh_kp.pk)}    sk={len(slh_kp.sk)}    (sk chmod 600)")
    print(f"  Ed25519      pk={len(ed_kp.pk)}      sk={len(ed_kp.sk)}      (sk chmod 600)")
    print()

    # ---- schema v2: bind the order to the execution it authorises ----
    #
    # The vault recomputes this commitment from its own calldata and reverts
    # on a mismatch, so the ML-DSA signature now covers WHAT executes, not
    # merely that an order existed. amount_out_min and deadline are inside the
    # commitment because they decide economic loss; leaving them out let the
    # broadcasting ECDSA key deviate from PQ-signed intent (contract M-7).
    exec_block = _build_route_execution(
        amount_in_wei=int(os.environ.get("DEMO_AMOUNT_IN_WEI", 10**17)),  # 0.1 MON
        slippage_bps=int(os.environ.get("DEMO_SLIPPAGE_BPS", 50)),
        valid_for_s=int(os.environ.get("DEMO_VALID_FOR_S", 300)),
    )

    order = orders.RebalanceOrder(
        pools=selected,
        weights=[weight] * len(selected),
        expected_return=float(metrics["return"]),
        expected_vol=float(metrics["volatility"]),
        qpu_job_id=qpu_job_id,
        qaoa_p_optimal=qaoa_p_opt,
        execution=exec_block,
    )
    signed = orders.sign_order_hedged(order, ml_kp, slh_kp, ed_kp)

    # M-1: verify against the keys we hold, not the ones in the artefact.
    trusted = orders.TrustedKeys(ml_dsa=ml_kp.pk, slh_dsa=slh_kp.pk, ed25519=ed_kp.pk)
    components = orders.verify_signed_order_components(signed)
    all_ok = orders.verify_signed_order(signed, trusted=trusted)
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
    print(f"Verified:    {all_ok}  (must be True, pinned to keys/*.pub)")
    print()

    monad_tx_mod = importlib.import_module("src.monad_tx")
    monad_tx_mod.validate_route_execution(exec_block)
    commitment = monad_tx_mod.route_commitment(exec_block)
    print("Execution binding (schema v2):")
    print(f"  user:          {exec_block.user}")
    print(f"  vault:         {exec_block.vault}")
    print(f"  tokenOuts:     {exec_block.token_outs}")
    print(f"  feeTiers:      {exec_block.fee_tiers}")
    print(f"  weightsBps:    {exec_block.weights_bps}")
    print(f"  amountIn:      {exec_block.amount_in_wei} wei")
    print(f"  amountOutMin:  {exec_block.amount_out_min}")
    print(f"  deadline:      {exec_block.deadline}")
    print(f"  execCommitment 0x{commitment.hex()}")
    print("  -> anchor(orderHash, execCommitment, seq) on AuditAnchorV2;")
    print("     the vault recomputes this and reverts on any divergence.")
    print()

    # Tamper test — uses a separate order COPY so the signed object is
    # not mutated (float round-trip via += / -= would invalidate the
    # signature against the fail-closed verify in append_audit).
    # Shift allocation BETWEEN legs so the sum stays 1.0 — otherwise the new
    # RebalanceOrder invariant rejects the tampered order at construction and
    # we would never reach the signature check we are trying to demonstrate.
    tampered_weights = list(signed.order.weights)
    tampered_weights[0] += 0.01
    tampered_weights[-1] -= 0.01
    tampered_signed = replace(signed, order=replace(signed.order, weights=tampered_weights))
    tampered_components = orders.verify_signed_order_components(tampered_signed)
    tampered_ok = orders.verify_signed_order(tampered_signed, trusted=trusted)
    print(f"Tamper test (0.01 shifted from the last leg to weights[0]):")
    print(f"  Components:  {tampered_components}")
    print(f"  Verified:    {tampered_ok}  (must be False)")
    print()

    orders.append_audit(signed, trusted=trusted)
    orders.save_signed_orders([signed])
    print(f"Wrote {orders.SIGNED_ORDERS_PATH} and appended to "
          f"{orders.AUDIT_LOG_PATH}")
    print()

    # ---- Unsigned Monad TXs ----
    from src import monad_tx

    # Both demo TXs target Monad TESTNET (chainId 10143) because the
    # deployed AuditAnchor address is a testnet artefact. The runtime
    # default `MONAD_CHAIN_ID` is mainnet (143) — passing the testnet
    # constant explicitly prevents a copy-paste from broadcasting on
    # the wrong chain.
    DEMO_CHAIN_ID = monad_tx.MONAD_TESTNET_CHAIN_ID

    # Path A: self-transfer-with-payload — embeds the entire signed order
    # in calldata. Heavy (~5 KB) but reviewer-readable on-chain.
    tx = monad_tx.build_unsigned_tx(
        signed, to_address=AGENT_WALLET_ADDR, nonce=0,
        chain_id=DEMO_CHAIN_ID,
    )
    tx_path = Path("outputs/unsigned_monad_tx.json")
    tx_path.write_text(json.dumps(tx.to_dict(), indent=2))
    print(f"Built unsigned self-transfer TX → {tx_path}")
    print(f"  chainId={tx.chainId}  to={tx.to}  calldata={len(tx.data)//2 - 1} bytes")

    # Path B: AuditAnchor — anchors only the 32-byte SHA-256, ~30 K gas.
    anchor_tx = monad_tx.build_anchor_tx(
        signed,
        anchor_contract=AUDIT_ANCHOR_TESTNET,
        nonce=0,
        expected_sequence=0,
        chain_id=DEMO_CHAIN_ID,
    )
    anchor_path = Path("outputs/unsigned_anchor_tx.json")
    anchor_path.write_text(json.dumps(anchor_tx.to_dict(), indent=2))
    print(f"Built unsigned anchor TX     → {anchor_path}")
    print(f"  chainId={anchor_tx.chainId}  to={anchor_tx.to}  "
          f"calldata={len(anchor_tx.data)//2 - 1} bytes  gas={anchor_tx.gas:,}")

    # Path C: MonadAllocationVault — deposits native MON under orderHash.
    # Real on-chain effect (msg.value moves into the vault), withdrawable
    # by the same wallet. Forms the third leg of the provenance trail:
    # signed_orders.json (off-chain) → AuditAnchor (on-chain hash) →
    # MonadAllocationVault (on-chain value + event).
    alloc_tx = monad_tx.build_alloc_tx(
        signed,
        vault_contract=ALLOC_VAULT_TESTNET,
        nonce=0,
        amount_wei=DEMO_ALLOC_WEI,
        chain_id=DEMO_CHAIN_ID,
    )
    alloc_path = Path("outputs/unsigned_alloc_tx.json")
    alloc_path.write_text(json.dumps(alloc_tx.to_dict(), indent=2))
    print(f"Built unsigned alloc TX      → {alloc_path}")
    print(f"  chainId={alloc_tx.chainId}  to={alloc_tx.to}  "
          f"value={alloc_tx.value} wei (0.01 MON)  gas={alloc_tx.gas:,}")
    print("  (sign with a wallet to broadcast — execution intentionally")
    print("   separated from PQ-signed authorisation; see SECURITY.md)")


if __name__ == "__main__":
    main()
