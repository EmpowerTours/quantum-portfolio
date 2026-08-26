#!/usr/bin/env bash
#
# Step 2 of 3: redeploy UniswapRoutingVault against MLDSAAttestationV2.
#
# RUN THIS IN A REAL TERMINAL WINDOW, with the deployer key already loaded into
# this shell (the same way step 1 was run). Nothing here reads, writes or echoes
# a key — it uses whatever the environment already holds, or the forge keystore.
#
#   ./deploy-vault.sh --dry-run    # preflight + simulation, never broadcasts
#   ./deploy-vault.sh              # same, then asks before sending
#
# WHY A SCRIPT AND NOT THE RUNBOOK ONE-LINER. `PQ_ATTESTATION` DEFAULTS TO V1
# inside DeployUniswapRoutingVault.s.sol, and the runbook's step-2 command does
# not set it. Running that command as written deploys a brand new vault still
# gated on the OLD attestation — a silent no-op that looks like a successful
# migration. This script pins it and refuses if it still resolves to v1.
#
set -euo pipefail

RPC="${RPC:-https://rpc.monad.xyz}"
CHAIN_ID=143

# --- the whole point of this deploy ------------------------------------------
export PQ_ATTESTATION="${PQ_ATTESTATION:-0xFeEf24A5dBF43E9dE8AC0d0EaB0f0141E980A52c}"
PQ_V1=0xb0aADaFe68647578520E988b4444e556c300b4Da

# --- unchanged, reused ------------------------------------------------------
# AuditAnchorV2 is NOT redeployed: its lastHash/nextSequence state is what the
# historical proof transactions in SUBMISSION.md depend on.
export AUDIT_ANCHOR_ADDR="${AUDIT_ANCHOR_ADDR:-0x8422b555DCE11913A4657C2f47C839637FC71ffd}"
# USDC. Only fee tier 3000 is allowlisted: the sibling pools hold 0.19 and 2.93
# USDC against ~447k in the 0.3% pool, so routing through them is a near-total
# loss (audit H-3).
export APPROVED_TOKENS="${APPROVED_TOKENS:-0x754704Bc059F8C67012fEd69BC8A327a5aafb603}"
export APPROVED_FEE_TIERS="${APPROVED_FEE_TIERS:-3000}"

DEPLOYER="${DEPLOYER:-0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1}"
ACCOUNT="${ACCOUNT:-deployer}"
export EXPECTED_DEPLOYER="$DEPLOYER"

# Monadscan verification. Etherscan V2 multichain endpoint — the chainid IN THE
# URL is what routes it, which is why no --chain flag is passed anywhere here.
VERIFIER_URL="${VERIFIER_URL:-https://api.etherscan.io/v2/api?chainid=143}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")"

die() { printf '\nREFUSING: %s\n' "$1" >&2; exit 1; }
say() { printf '  %s\n' "$1"; }

if [ ! -t 0 ] || [ ! -t 1 ]; then
    die "no TTY. Run this in a terminal window, not through Claude Code's \`!\`
          prefix or an agent shell tool."
fi

command -v forge >/dev/null || die "forge not on PATH"
command -v cast  >/dev/null || die "cast not on PATH"

echo
echo "=== preflight ==============================================="

got_chain=$(cast chain-id --rpc-url "$RPC")
[ "$got_chain" = "$CHAIN_ID" ] || die "RPC reports chain $got_chain, expected $CHAIN_ID"
say "chain id           $got_chain"

# --- the migration actually migrates ----------------------------------------
if [ "${PQ_ATTESTATION,,}" = "${PQ_V1,,}" ]; then
    die "PQ_ATTESTATION is still v1 ($PQ_V1). Deploying this would produce a
          new vault gated on the OLD attestation — a migration that changes
          nothing while looking like it worked."
fi
sz=$(cast codesize "$PQ_ATTESTATION" --rpc-url "$RPC")
[ "$sz" -gt 0 ] || die "PQ_ATTESTATION $PQ_ATTESTATION has no code"
say "PQ attestation     $PQ_ATTESTATION ($sz bytes)"

# It must really be a V2: v1 has no agentPkCount(). This is the cheapest proof
# that the address is the rotation-capable contract and not something else.
cnt=$(cast call "$PQ_ATTESTATION" 'agentPkCount()(uint256)' --rpc-url "$RPC" 2>/dev/null || echo "")
[ -n "$cnt" ] || die "$PQ_ATTESTATION has no agentPkCount() — not an MLDSAAttestationV2"
say "  agentPkCount     $cnt"
say "  guardian         $(cast call "$PQ_ATTESTATION" 'guardian()(address)' --rpc-url "$RPC")"

# --- the anchor is the V2 anchor, and is being REUSED -----------------------
asz=$(cast codesize "$AUDIT_ANCHOR_ADDR" --rpc-url "$RPC")
[ "$asz" -gt 0 ] || die "AUDIT_ANCHOR_ADDR $AUDIT_ANCHOR_ADDR has no code"
say "audit anchor       $AUDIT_ANCHOR_ADDR ($asz bytes, reused not redeployed)"

say "approved tokens    $APPROVED_TOKENS"
say "approved fees      $APPROVED_FEE_TIERS"

bal=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
say "deployer           $DEPLOYER"
say "deployer balance   $(cast from-wei "$bal") MON"
[ "$(cast from-wei "$bal" | cut -d. -f1)" -ge 2 ] || die "deployer balance under 2 MON"

echo
echo "=== simulation =============================================="
if [ -n "${DEPLOYER_PRIVATE_KEY:-}" ]; then
    forge script script/DeployUniswapRoutingVault.s.sol --rpc-url "$RPC"
else
    forge script script/DeployUniswapRoutingVault.s.sol \
        --rpc-url "$RPC" --sender "$DEPLOYER"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "--dry-run: stopping here. Nothing was broadcast."
    exit 0
fi

cat <<EOF

=== about to BROADCAST to Monad mainnet =====================

  UniswapRoutingVault, immutable, permanent.
    PQ (attestation)   $PQ_ATTESTATION   <-- V2, the point of this deploy
    ANCHOR             $AUDIT_ANCHOR_ADDR
    approved tokens    $APPROVED_TOKENS
    approved fees      $APPROVED_FEE_TIERS
    from               $DEPLOYER

  This RETIRES UniswapRoutingVault 0xDaEa22D6DCB37FBF1462d6d08ADE40A8fAc05144.
  It holds no assets and the deployer has no allowance to it, so nothing needs
  migrating — but every document citing the old address becomes stale the
  moment this lands.

EOF
printf "Type DEPLOY to broadcast, anything else to abort: "
read -r answer
[ "$answer" = "DEPLOY" ] || { echo "aborted; nothing was sent."; exit 1; }

echo
echo "=== broadcasting ============================================"
if [ -n "${DEPLOYER_PRIVATE_KEY:-}" ]; then
    forge script script/DeployUniswapRoutingVault.s.sol --rpc-url "$RPC" --broadcast
else
    forge script script/DeployUniswapRoutingVault.s.sol \
        --rpc-url "$RPC" --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast
fi

ADDR=$(python3 -c "
import json
d=json.load(open('broadcast/DeployUniswapRoutingVault.s.sol/$CHAIN_ID/run-latest.json'))
print(next(t['contractAddress'] for t in d['transactions'] if t['transactionType']=='CREATE'))
" 2>/dev/null || true)

echo
echo "=== deployed ================================================"
echo "  UniswapRoutingVault  $ADDR"

# Assert, do not suggest. A vault that deployed against the wrong attestation
# is the exact failure this script exists to prevent, and printing a command
# for someone to maybe run later is not prevention.
got_pq=$(cast call "$ADDR" 'PQ()(address)' --rpc-url "$RPC")
got_anchor=$(cast call "$ADDR" 'ANCHOR()(address)' --rpc-url "$RPC")
if [ "${got_pq,,}" != "${PQ_ATTESTATION,,}" ]; then
    die "DEPLOYED VAULT POINTS AT THE WRONG ATTESTATION.
          PQ() = $got_pq
          expected $PQ_ATTESTATION
          Do NOT cite this vault anywhere; redeploy."
fi
if [ "${got_anchor,,}" != "${AUDIT_ANCHOR_ADDR,,}" ]; then
    die "deployed vault ANCHOR() = $got_anchor, expected $AUDIT_ANCHOR_ADDR"
fi
say "PQ()                 $got_pq  (V2, asserted)"
say "ANCHOR()             $got_anchor  (asserted)"
echo
echo "=== verify on Monadscan ====================================="
echo "  Constructor args, re-encoded from the LIVE contract:"
CTOR=$(cast abi-encode "c(address,address,address,address,address[],uint24[])" \
    "$(cast call "$ADDR" 'WRAPPED_MON()(address)' --rpc-url "$RPC")" \
    "$(cast call "$ADDR" 'ROUTER()(address)' --rpc-url "$RPC")" \
    "$(cast call "$ADDR" 'ANCHOR()(address)' --rpc-url "$RPC")" \
    "$(cast call "$ADDR" 'PQ()(address)' --rpc-url "$RPC")" \
    "[$APPROVED_TOKENS]" "[$APPROVED_FEE_TIERS]" 2>/dev/null || echo "ENCODE_FAILED")
echo "    $CTOR"
echo
echo "  If that says ENCODE_FAILED the constructor signature differs — read it"
echo "  from src/UniswapRoutingVault.sol and encode by hand rather than guessing."
echo
echo "=== next ===================================================="
echo "  3. MorphoSupplyAdapter, with PQ_ATTESTATION=$PQ_ATTESTATION"
echo "     Verify this vault on Monadscan BEFORE starting it."
