#!/usr/bin/env bash
#
# Phase 3 PLANNER for the 2026-08-25 re-run.
#
# This script never reads a key, never signs, and never broadcasts. It runs
# every preflight check that could otherwise cost you a wasted proof or a burnt
# anchor sequence, works out which of the six steps the chain says are still
# outstanding, and PRINTS the exact commands for those steps. You paste them.
#
#   ./plan-loop.sh
#
# Re-run it any time. It reads on-chain state fresh each run, so after you
# paste a step it drops out of the plan automatically.
#
set -euo pipefail
cd "$(dirname "$0")"

RPC="${RPC:-https://rpc.monad.xyz}"
CHAIN_ID=143
USER_ADDR="${USER_ADDR:-0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1}"
ATT="${ATT:-0xFeEf24A5dBF43E9dE8AC0d0EaB0f0141E980A52c}"
ANCHOR="${ANCHOR:-0x8422b555DCE11913A4657C2f47C839637FC71ffd}"
VAULT="${VAULT:-0xcC60db5E123Cb3150d5F11CA5526a79B4f31113F}"
ADAPTER="${ADAPTER:-0x6D42fA32880aDd1d794abBF98c5Cd104Fe332D89}"
USDC="${USDC:-0x754704Bc059F8C67012fEd69BC8A327a5aafb603}"
WBTC=0x0555E30da8f98308EdB960aa94C0Db47230d2B9c
ORACLE=0xff07261c87763cc5693ab78746d0b6735Ec626F5
IRM=0x09475a3D6eA8c314c592b1a3799bDE044E2F400F
LLTV=860000000000000000
MARKET="($USDC,$WBTC,$ORACLE,$IRM,$LLTV)"

FIX_ROUTE=zk-mldsa/contracts/src/fixtures/groth16-mldsa-route.json
FIX_SUPPLY=zk-mldsa/contracts/src/fixtures/groth16-mldsa-supply.json
PRE_ROUTE=outputs/preimage_route.hex
PRE_SUPPLY=outputs/preimage_supply.hex

export PATH="$HOME/.foundry/bin:$PATH"
PY=./.venv/bin/python
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000

die() { printf '\nREFUSING: %s\n' "$1" >&2; exit 1; }
say() { printf '  %s\n' "$1"; }
ok()  { printf '  [done] %s\n' "$1"; }
todo(){ printf '  [TODO] %s\n' "$1"; }

command -v cast >/dev/null || die "cast not on PATH"
[ -x "$PY" ] || die "no venv python at $PY"

echo
echo "=== preflight ==============================================="
[ "$(cast chain-id --rpc-url "$RPC")" = "$CHAIN_ID" ] || die "wrong chain"
say "chain id           $CHAIN_ID"

# --- every value comes OUT OF THE SIGNED ORDERS, never retyped --------------
eval "$($PY - <<'PYEOF'
import sys
from pathlib import Path
sys.path.insert(0, '.')
from src import monad_tx, orders, pq_signing as pq

r = orders.load_signed_orders()[0]
rex, roh = r.order.execution, monad_tx.order_sha256(orders.load_signed_orders()[0])
s = orders.load_signed_orders(path=Path('outputs/mainnet_supply_order.json'))[0]
sex, soh = s.order.execution, monad_tx.order_sha256(s)

Path('outputs/preimage_route.hex').write_text(
    "0x" + pq.canonical_bytes(r.order.to_dict()).hex())
Path('outputs/preimage_supply.hex').write_text(
    "0x" + pq.canonical_bytes(s.order.to_dict()).hex())

print(f"OH_R=0x{roh.hex()}")
print(f"CM_R=0x{monad_tx.route_commitment(rex, roh).hex()}")
print(f"DEADLINE={rex.deadline}")
print(f"AMT_IN={rex.amount_in_wei}")
print(f"FLOOR={rex.amount_out_min[0]}")
print(f"VAULT_SIGNED={rex.vault}")
print(f"OH_S=0x{soh.hex()}")
print(f"CM_S=0x{monad_tx.supply_commitment(sex, soh).hex()}")
print(f"MAXA={sex.max_assets}")
print(f"ADAPTER_SIGNED={sex.adapter}")
PYEOF
)"

say "route  orderHash   $OH_R"
say "supply orderHash   $OH_S"

# The orders must name the executors this plan targets, or every step below
# would be aimed at the wrong contract.
[ "${VAULT_SIGNED,,}"   = "${VAULT,,}" ]   || die "route order names vault $VAULT_SIGNED, not $VAULT"
[ "${ADAPTER_SIGNED,,}" = "${ADAPTER,,}" ] || die "supply order names adapter $ADAPTER_SIGNED, not $ADAPTER"
say "orders name the deployed executors"

# --- the deadline is inside exec_commitment and cannot be extended ----------
NOW=$(date -u +%s)
LEFT=$(( DEADLINE - NOW ))
[ "$LEFT" -gt 600 ] || die "route deadline $DEADLINE has under 10 minutes left.
      Both orders must be re-signed AND re-proved — the deadline is sealed
      inside exec_commitment."
say "route deadline     $DEADLINE  ($((LEFT/3600))h left)"

# --- proofs, if present, must be FOR THESE ORDERS and the pinned vkey -------
HAVE_PROOFS=1
for f in "$FIX_ROUTE" "$FIX_SUPPLY"; do [ -f "$f" ] || HAVE_PROOFS=0; done

if [ "$HAVE_PROOFS" -eq 1 ]; then
    VKEY=$(cast call "$ATT" 'mldsaProgramVKey()(bytes32)' --rpc-url "$RPC")
    for pair in "route:$FIX_ROUTE:$OH_R" "supply:$FIX_SUPPLY:$OH_S"; do
        leg=${pair%%:*}; rest=${pair#*:}; fix=${rest%%:*}; want=${rest#*:}
        $PY - "$fix" "$want" "$VKEY" "$leg" <<'PYEOF'
import json, sys
fix, want, vkey, leg = sys.argv[1:5]
d = json.load(open(fix)); pv = d["publicValues"][2:]
if len(pv) != 128:
    sys.exit(f"  {leg}: publicValues is {len(pv)//2} bytes, expected 64")
got = "0x" + pv[:64]
if got.lower() != want.lower():
    sys.exit(f"  {leg}: the proof commits orderHash {got}\n"
             f"        but the signed order is      {want}\n"
             f"        This proof cannot attest this order.")
if d["vkey"].lower() != vkey.lower():
    sys.exit(f"  {leg}: fixture vkey {d['vkey']}\n"
             f"        on-chain vkey {vkey}\n"
             f"        attest() would revert — proof built from a different guest.")
print(f"  {leg} proof       commits the right order, vkey matches the contract")
PYEOF
    done
else
    say "proofs             NOT PRESENT YET — run zk-mldsa/prove-both.sh"
fi

# --- the executors must recompute the signed commitments -------------------
GOT_R=$(cast call "$VAULT" 'routeCommitment(bytes32,address,address[],uint24[],uint16[],uint256,uint256[],uint256)(bytes32)' \
    "$OH_R" "$USER_ADDR" "[$USDC]" "[3000]" "[10000]" "$AMT_IN" "[$FLOOR]" "$DEADLINE" --rpc-url "$RPC")
[ "${GOT_R,,}" = "${CM_R,,}" ] || die "route commitment mismatch
      vault recomputes $GOT_R
      order was signed $CM_R"
GOT_S=$(cast call "$ADAPTER" 'supplyCommitment(bytes32,address,(address,address,address,address,uint256),uint256)(bytes32)' \
    "$OH_S" "$USER_ADDR" "$MARKET" "$MAXA" --rpc-url "$RPC")
[ "${GOT_S,,}" = "${CM_S,,}" ] || die "supply commitment mismatch
      adapter recomputes $GOT_S
      order was signed   $CM_S"
say "commitments        both match the deployed executors"

BAL=$(cast balance "$USER_ADDR" --rpc-url "$RPC")
say "deployer balance   $(cast from-wei "$BAL") MON"
say "swap amount        $(cast from-wei "$AMT_IN") MON, floor $FLOOR micro-USDC"
say "supply ceiling     $MAXA micro-USDC"

# --- what the chain says is already done ------------------------------------
echo
echo "=== progress ================================================"
A_R=$(cast call "$ATT" 'pqAttested(bytes32)(bool)' "$OH_R" --rpc-url "$RPC")
N_R=$(cast call "$ANCHOR" 'execCommitmentOf(address,bytes32)(bytes32)' "$USER_ADDR" "$OH_R" --rpc-url "$RPC")
X_R=$(cast call "$VAULT" 'consumed(address,bytes32)(bool)' "$USER_ADDR" "$OH_R" --rpc-url "$RPC")
A_S=$(cast call "$ATT" 'pqAttested(bytes32)(bool)' "$OH_S" --rpc-url "$RPC")
N_S=$(cast call "$ANCHOR" 'execCommitmentOf(address,bytes32)(bytes32)' "$USER_ADDR" "$OH_S" --rpc-url "$RPC")
X_S=$(cast call "$ADAPTER" 'consumed(address,bytes32)(bool)' "$USER_ADDR" "$OH_S" --rpc-url "$RPC")

[ "$A_R" = "true" ]  && ok "1 attest(route)"     || todo "1 attest(route)"
[ "$N_R" != "$ZERO" ] && ok "2 anchor(route)"    || todo "2 anchor(route)"
[ "$X_R" = "true" ]  && ok "3 executeAndRoute"   || todo "3 executeAndRoute"
[ "$A_S" = "true" ]  && ok "4 attest(supply)"    || todo "4 attest(supply)"
[ "$N_S" != "$ZERO" ] && ok "5 anchor(supply)"   || todo "5 anchor(supply)"
[ "$X_S" = "true" ]  && ok "6 supply"            || todo "6 supply"

SEQ=$(cast call "$ANCHOR" 'nextSequence(address)(uint64)' "$USER_ADDR" --rpc-url "$RPC")
# The supply anchor lands AFTER the route anchor, so it consumes the next
# sequence number. If the route anchor is already done, they are the same.
if [ "$N_R" = "$ZERO" ]; then SEQ_S=$((SEQ + 1)); else SEQ_S=$SEQ; fi

USDC_BAL=$(cast call "$USDC" 'balanceOf(address)(uint256)' "$USER_ADDR" --rpc-url "$RPC" | awk '{print $1}')

echo
echo "=== commands to paste ======================================="
cat <<'HDR'
  Load the key into THIS shell first (it never enters this script):

    set +o history
    eval "export $(grep -m1 '^DEPLOYER_PRIVATE_KEY=' ~/projects/fcempowertours/.env)"
    DEPLOYER_PRIVATE_KEY=${DEPLOYER_PRIVATE_KEY%$'\r'}

  Paranoid alternative: drop --private-key and use -i, which prompts.
  Run them IN ORDER and re-run ./plan-loop.sh after each to confirm.

HDR

K='--private-key "$DEPLOYER_PRIVATE_KEY"'
R="--rpc-url $RPC"

if [ "$HAVE_PROOFS" -eq 0 ]; then
    echo "  (steps 1 and 4 need the proofs; generate them first)"
    echo
fi

if [ "$A_R" != "true" ] && [ "$HAVE_PROOFS" -eq 1 ]; then
cat <<EOF
# 1. attest the ROUTE proof
cast send $ATT 'attest(bytes,bytes)' \\
  \$($PY -c "import json;print(json.load(open('$FIX_ROUTE'))['publicValues'])") \\
  \$($PY -c "import json;print(json.load(open('$FIX_ROUTE'))['proof'])") \\
  $R $K

EOF
fi

if [ "$N_R" = "$ZERO" ]; then
cat <<EOF
# 2. anchor the ROUTE commitment  (expectedSequence must equal nextSequence NOW)
cast send $ANCHOR 'anchor(bytes32,bytes32,uint64)' \\
  $OH_R $CM_R $SEQ \\
  $R $K

EOF
fi

if [ "$X_R" != "true" ]; then
cat <<EOF
# 3. execute the swap — SPENDS $(cast from-wei "$AMT_IN") MON
cast send $VAULT \\
  'executeAndRoute(bytes32,address[],uint24[],uint16[],uint256[],uint256,bytes)' \\
  $OH_R "[$USDC]" "[3000]" "[10000]" "[$FLOOR]" $DEADLINE \\
  \$(cat $PRE_ROUTE) \\
  --value $AMT_IN $R $K

EOF
fi

if [ "$A_S" != "true" ] && [ "$HAVE_PROOFS" -eq 1 ]; then
cat <<EOF
# 4. attest the SUPPLY proof
cast send $ATT 'attest(bytes,bytes)' \\
  \$($PY -c "import json;print(json.load(open('$FIX_SUPPLY'))['publicValues'])") \\
  \$($PY -c "import json;print(json.load(open('$FIX_SUPPLY'))['proof'])") \\
  $R $K

EOF
fi

if [ "$N_S" = "$ZERO" ]; then
cat <<EOF
# 5. anchor the SUPPLY commitment
#    Sequence is $SEQ_S because step 2 consumes $SEQ first. anchor() reverts on
#    disagreement rather than mis-filing, so a wrong number costs gas only.
cast send $ANCHOR 'anchor(bytes32,bytes32,uint64)' \\
  $OH_S $CM_S $SEQ_S \\
  $R $K

EOF
fi

if [ "$X_S" != "true" ]; then
cat <<EOF
# 6. approve, then supply. supply() does safeTransferFrom(msg.sender, ...),
#    so the adapter needs an allowance. Your USDC balance right now is
#    $USDC_BAL micro-USDC; the signed ceiling is $MAXA. Supply min(balance, ceiling)
#    AFTER step 3 has landed — the balance below is stale until then.
cast send $USDC 'approve(address,uint256)' $ADAPTER <ASSETS> $R $K

cast send $ADAPTER \\
  'supply(bytes32,(address,address,address,address,uint256),uint256,uint256,bytes)' \\
  $OH_S "$MARKET" <ASSETS> $MAXA \\
  \$(cat $PRE_SUPPLY) \\
  $R $K

EOF
fi

if [ "$X_R" = "true" ] && [ "$X_S" = "true" ]; then
    echo "  Nothing outstanding — the loop is complete on the new contracts."
    echo "  Collect the six tx hashes; verify_claims.py's TXS map still points"
    echo "  at the 2026-08-11 run on the retired pair."
fi

echo "  preimages written to $PRE_ROUTE and $PRE_SUPPLY"
