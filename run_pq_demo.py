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
    outputs/unsigned_anchor_tx.json — wallet-ready AuditAnchorV2 TX (mainnet)
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
import sys
import time
from dataclasses import replace
from pathlib import Path

from src import orders, pq_signing as pq, quoter

# --- Monad mainnet (chainId 143) constants, on-chain verified 2026-07-28 ---
MONAD_MAINNET_CHAIN_ID = 143
USDC_MAINNET = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"
USDC_FEE_TIER = 3000          # the only genuinely liquid WMON/USDC pool

WMON_MAINNET = "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A"


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
        raise SystemExit(
            "UNISWAP_ROUTING_VAULT and AGENT_ADDRESS must be set.\n"
            "A zero vault or user produces a commitment that can NEVER be "
            "satisfied (msg.sender is never 0), and anchoring it would brick "
            "that orderHash permanently — AuditAnchorV2 refuses to re-anchor."
        )

    # The floor MUST come from a live quote. This used to fall back to a
    # hardcoded reference rate with a printed warning, which is the failure
    # mode it was warning about: the constant was accurate to +0.004% when
    # captured and had drifted -1.17% six hours later — enough to push a 50 bps
    # floor below the live quote and revert every order until the deadline
    # burned the anchor. Drift the other way silently under-protects. Since the
    # signed floor is the entire MEV defence (contract RT04c), there is no safe
    # default here, so failure to quote refuses to sign rather than guessing.
    expected_micro = int(os.environ.get("DEMO_EXPECTED_OUT_MICRO", 0)) or None
    if expected_micro is None:
        try:
            expected_out = quoter.quote_exact_input_single(
                WMON_MAINNET, USDC_MAINNET, amount_in_wei, USDC_FEE_TIER
            )
        except quoter.QuoteError as exc:
            raise SystemExit(
                f"could not obtain a live quote: {exc}\n"
                "Refusing to sign an order whose slippage floor would be based "
                "on a stale hardcoded rate. Set DEMO_EXPECTED_OUT_MICRO "
                "explicitly if you have a quote from another source."
            ) from exc
        print(f"live quote (QuoterV2): {amount_in_wei} wei MON -> "
              f"{expected_out} micro-USDC @ tier {USDC_FEE_TIER}")
    else:
        expected_out = expected_micro

    if not (0 < slippage_bps <= 500):
        raise ValueError(f"DEMO_SLIPPAGE_BPS must be in (0, 500], got {slippage_bps}")
    floor = expected_out * (10_000 - slippage_bps) // 10_000
    if floor <= 0:
        raise ValueError(
            f"computed amountOutMin is {floor} for amount_in={amount_in_wei} wei. "
            "Refusing to sign a fail-open slippage floor — clamping this to 1 "
            "would authorise a ~100% loss."
        )
    return orders.RouteExecution(
        chain_id=MONAD_MAINNET_CHAIN_ID,
        vault=vault,
        user=user,
        token_outs=[USDC_MAINNET],
        fee_tiers=[USDC_FEE_TIER],
        weights_bps=[10_000],
        amount_in_wei=amount_in_wei,
        amount_out_min=[floor],
        deadline=int(time.time()) + valid_for_s,
    )

HARDWARE_RUN_DEFI   = Path("outputs/hardware_run_defi.json")
HARDWARE_RUN_STOCKS = Path("outputs/hardware_run.json")
KEYS_DIR            = Path("keys")

# AuditAnchorV2 on Monad MAINNET (chainId 143), Monadscan-verified. This is
# the anchor the live loop uses; V1 below has code only on testnet.
AUDIT_ANCHOR_V2_MAINNET = "0x8422b555DCE11913A4657C2f47C839637FC71ffd"

# Testnet-only, and superseded. MonadAllocationVault was the first
# custody-with-attribution experiment; UniswapRoutingVault +
# MorphoSupplyAdapter on mainnet replaced it. `cast codesize` returns 0 for
# both of these on mainnet, so Path C below is explicitly labelled testnet
# rather than being silently emitted with a mainnet chainId.
AUDIT_ANCHOR_V1_TESTNET = "0x0e649C383CFA6be1998445D0A7a8E1cc7540D239"
ALLOC_VAULT_TESTNET     = "0xC39e298ce89cDfc934c697c9Fe0CC4BAA80B87f5"

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


def _guard_shipped_evidence() -> None:
    """Refuse to silently replace an order that is anchored on-chain.

    outputs/signed_orders.json is not scratch output: the order it holds is
    the one whose SHA-256 and execution commitment were anchored on Monad
    mainnet, and outputs/executed_anchor_tx.json plus the Streamlit PQ panel
    both recompute against it. A plain `python run_pq_demo.py` used to
    overwrite it, which severs that link with no warning — the artefact still
    looks fine, it just no longer corresponds to any transaction on chain.

    Pass --replace-shipped when replacing it is what you actually mean.
    """
    if "--replace-shipped" in sys.argv:
        return
    if not orders.SIGNED_ORDERS_PATH.exists():
        return
    raise SystemExit(
        f"{orders.SIGNED_ORDERS_PATH} already exists and holds the order that\n"
        "is anchored on Monad mainnet (see outputs/executed_anchor_tx.json).\n"
        "Overwriting it would break the recomputation the app and\n"
        "verify_claims.py rely on, with no visible symptom.\n\n"
        "  python run_pq_demo.py --replace-shipped   # yes, replace it\n"
    )


def main() -> None:
    _guard_shipped_evidence()
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
    # The commitment leads with the orderHash: `consumed` is keyed by
    # orderHash, so a commitment that did not name its own order could be
    # filed under unlimited distinct orderHashes and executed once under each.
    # (Audit RT08e.)
    order_hash = monad_tx_mod.order_sha256(signed)
    commitment = monad_tx_mod.route_commitment(exec_block, order_hash)
    print("Execution binding (schema v2):")
    print(f"  orderHash:     0x{order_hash.hex()}")
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

    # Paths A and B target Monad MAINNET (143): AuditAnchorV2 is deployed
    # there and the full loop executed against it. Path C is the one leg
    # still pinned to testnet, because MonadAllocationVault has no mainnet
    # code — it is passed the testnet id explicitly so a copy-paste cannot
    # broadcast it on the wrong chain.
    DEMO_CHAIN_ID    = monad_tx.MONAD_CHAIN_ID
    TESTNET_CHAIN_ID = monad_tx.MONAD_TESTNET_CHAIN_ID

    # Path A: self-transfer-with-payload — embeds the entire signed order
    # in calldata. Heavy (~5 KB) but reviewer-readable on-chain.
    tx = monad_tx.build_unsigned_tx(
        signed, to_address=AGENT_WALLET_ADDR, nonce=0,
        chain_id=DEMO_CHAIN_ID, trusted=trusted,
    )
    tx_path = Path("outputs/unsigned_monad_tx.json")
    tx_path.write_text(json.dumps(tx.to_dict(), indent=2))
    print(f"Built unsigned self-transfer TX → {tx_path}")
    print(f"  chainId={tx.chainId}  to={tx.to}  calldata={len(tx.data)//2 - 1} bytes")

    # Path B: AuditAnchorV2 — anchors the 32-byte SHA-256 plus the
    # execution commitment, on mainnet.
    # V2, not V1: V1 carries no execution commitment, so the vault's
    # recompute-and-revert defence cannot be armed by a V1 anchor.
    anchor_tx = monad_tx.build_anchor_v2_tx(
        signed,
        anchor_contract=AUDIT_ANCHOR_V2_MAINNET,
        nonce=0,
        expected_sequence=0,
        trusted=trusted,
    )
    anchor_path = Path("outputs/unsigned_anchor_tx.json")
    anchor_path.write_text(json.dumps(anchor_tx.to_dict(), indent=2))
    print(f"Built unsigned anchor TX     → {anchor_path}")
    print(f"  chainId={anchor_tx.chainId}  to={anchor_tx.to}  "
          f"calldata={len(anchor_tx.data)//2 - 1} bytes  gas={anchor_tx.gas:,}")

    # Path C: MonadAllocationVault (TESTNET ONLY — no mainnet code).
    # Deposits native MON under orderHash.
    # Real on-chain effect (msg.value moves into the vault), withdrawable
    # by the same wallet. Forms the third leg of the provenance trail:
    # signed_orders.json (off-chain) → AuditAnchor (on-chain hash) →
    # MonadAllocationVault (on-chain value + event).
    alloc_tx = monad_tx.build_alloc_tx(
        signed,
        vault_contract=ALLOC_VAULT_TESTNET,
        nonce=0,
        amount_wei=DEMO_ALLOC_WEI,
        chain_id=TESTNET_CHAIN_ID,
        trusted=trusted,
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
