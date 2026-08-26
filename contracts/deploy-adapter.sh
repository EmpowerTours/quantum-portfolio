#!/usr/bin/env bash
#
# Step 3 of 3: redeploy MorphoSupplyAdapter against MLDSAAttestationV2.
#
# RUN THIS IN A REAL TERMINAL WINDOW, with the deployer key already loaded into
# this shell. Nothing here reads, writes or echoes a key.
#
#   ./deploy-adapter.sh --dry-run    # preflight + simulation, never broadcasts
#   ./deploy-adapter.sh              # same, then asks before sending
#
# Same footgun as the vault: `PQ_ATTESTATION` DEFAULTS TO V1 inside
# DeployMorphoSupplyAdapter.s.sol and the runbook's step-3 command does not set
# it, so running that as written redeploys against the OLD attestation. This
# script pins it and refuses if it still resolves to v1.
#
set -euo pipefail

RPC="${RPC:-https://rpc.monad.xyz}"
CHAIN_ID=143

export PQ_ATTESTATION="${PQ_ATTESTATION:-0xFeEf24A5dBF43E9dE8AC0d0EaB0f0141E980A52c}"
PQ_V1=0xb0aADaFe68647578520E988b4444e556c300b4Da

# AuditAnchorV2 reused, not redeployed — its lastHash/nextSequence state backs
# the historical proof transactions in SUBMISSION.md.
export AUDIT_ANCHOR_ADDR="${AUDIT_ANCHOR_ADDR:-0x8422b555DCE11913A4657C2f47C839637FC71ffd}"
export APPROVED_TOKENS="${APPROVED_TOKENS:-0x754704Bc059F8C67012fEd69BC8A327a5aafb603}"
# The script resolves this market id against Morpho itself and requires its loan
# token to be in APPROVED_TOKENS, so a typo fails closed rather than deploying a
# permanently unusable adapter.
export APPROVED_MARKETS="${APPROVED_MARKETS:-0xe35c5abc6418b6319b014e07aa3c86163a870a957284128f03cf7a9e414f8899}"

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

if [ "${PQ_ATTESTATION,,}" = "${PQ_V1,,}" ]; then
    die "PQ_ATTESTATION is still v1 ($PQ_V1). This would deploy an adapter
          gated on the OLD attestation — a migration that changes nothing."
fi
sz=$(cast codesize "$PQ_ATTESTATION" --rpc-url "$RPC")
[ "$sz" -gt 0 ] || die "PQ_ATTESTATION $PQ_ATTESTATION has no code"
say "PQ attestation     $PQ_ATTESTATION ($sz bytes)"

cnt=$(cast call "$PQ_ATTESTATION" 'agentPkCount()(uint256)' --rpc-url "$RPC" 2>/dev/null || echo "")
[ -n "$cnt" ] || die "$PQ_ATTESTATION has no agentPkCount() — not an MLDSAAttestationV2"
say "  agentPkCount     $cnt"

# The vault from step 2 must already be on the SAME attestation. Deploying the
# adapter against a different one would leave the two legs of the system gated
# on different registries, which is worse than not migrating at all.
VAULT="${VAULT:-0xcC60db5E123Cb3150d5F11CA5526a79B4f31113F}"
vpq=$(cast call "$VAULT" 'PQ()(address)' --rpc-url "$RPC" 2>/dev/null || echo "")
if [ -n "$vpq" ] && [ "${vpq,,}" != "${PQ_ATTESTATION,,}" ]; then
    die "step-2 vault $VAULT has PQ() = $vpq, not $PQ_ATTESTATION.
          The two legs would end up on different attestation registries."
fi
say "step-2 vault       $VAULT (PQ matches)"

asz=$(cast codesize "$AUDIT_ANCHOR_ADDR" --rpc-url "$RPC")
[ "$asz" -gt 0 ] || die "AUDIT_ANCHOR_ADDR has no code"
say "audit anchor       $AUDIT_ANCHOR_ADDR ($asz bytes, reused)"
say "approved tokens    $APPROVED_TOKENS"
say "approved markets   $APPROVED_MARKETS"

bal=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
say "deployer           $DEPLOYER"
say "deployer balance   $(cast from-wei "$bal") MON"
[ "$(cast from-wei "$bal" | cut -d. -f1)" -ge 2 ] || die "deployer balance under 2 MON"

echo
echo "=== simulation =============================================="
if [ -n "${DEPLOYER_PRIVATE_KEY:-}" ]; then
    forge script script/DeployMorphoSupplyAdapter.s.sol --rpc-url "$RPC"
else
    forge script script/DeployMorphoSupplyAdapter.s.sol \
        --rpc-url "$RPC" --sender "$DEPLOYER"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "--dry-run: stopping here. Nothing was broadcast."
    exit 0
fi

cat <<EOF

=== about to BROADCAST to Monad mainnet =====================

  MorphoSupplyAdapter, immutable, permanent.
    PQ (attestation)   $PQ_ATTESTATION   <-- V2, the point of this deploy
    ANCHOR             $AUDIT_ANCHOR_ADDR
    approved tokens    $APPROVED_TOKENS
    approved markets   $APPROVED_MARKETS
    from               $DEPLOYER

  This RETIRES MorphoSupplyAdapter 0xE3de921790d04656F2640fA1eDD75492e911Ffa6
  and COMPLETES the migration: after this, both executors gate on V2 and the
  agent key is rotatable without touching any of them again.

EOF
printf "Type DEPLOY to broadcast, anything else to abort: "
read -r answer
[ "$answer" = "DEPLOY" ] || { echo "aborted; nothing was sent."; exit 1; }

echo
echo "=== broadcasting ============================================"
if [ -n "${DEPLOYER_PRIVATE_KEY:-}" ]; then
    forge script script/DeployMorphoSupplyAdapter.s.sol --rpc-url "$RPC" --broadcast
else
    forge script script/DeployMorphoSupplyAdapter.s.sol \
        --rpc-url "$RPC" --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast
fi

ADDR=$(python3 -c "
import json
d=json.load(open('broadcast/DeployMorphoSupplyAdapter.s.sol/$CHAIN_ID/run-latest.json'))
print(next(t['contractAddress'] for t in d['transactions'] if t['transactionType']=='CREATE'))
" 2>/dev/null || true)

echo
echo "=== deployed ================================================"
echo "  MorphoSupplyAdapter  $ADDR"

got_pq=$(cast call "$ADDR" 'PQ()(address)' --rpc-url "$RPC")
got_anchor=$(cast call "$ADDR" 'ANCHOR()(address)' --rpc-url "$RPC")
if [ "${got_pq,,}" != "${PQ_ATTESTATION,,}" ]; then
    die "DEPLOYED ADAPTER POINTS AT THE WRONG ATTESTATION.
          PQ() = $got_pq, expected $PQ_ATTESTATION. Do NOT cite it; redeploy."
fi
[ "${got_anchor,,}" = "${AUDIT_ANCHOR_ADDR,,}" ] \
    || die "deployed adapter ANCHOR() = $got_anchor, expected $AUDIT_ANCHOR_ADDR"
say "PQ()                 $got_pq  (V2, asserted)"
say "ANCHOR()             $got_anchor  (asserted)"

echo
echo "=== verify on Monadscan ====================================="
echo "  Constructor args, re-encoded from the LIVE contract:"
CTOR=$(cast abi-encode "c(address,address,address,address[],bytes32[])" \
    "$(cast call "$ADDR" 'MORPHO()(address)' --rpc-url "$RPC")" \
    "$got_anchor" "$got_pq" \
    "[$APPROVED_TOKENS]" "[$APPROVED_MARKETS]" 2>/dev/null || echo "ENCODE_FAILED")
echo "    $CTOR"

echo
echo "=== migration complete ======================================"
echo "  Both executors now gate on MLDSAAttestationV2. Confirm the whole set:"
echo "    cast call $VAULT 'PQ()(address)' --rpc-url $RPC"
echo "    cast call $ADDR 'PQ()(address)' --rpc-url $RPC"
echo "  Both must return $PQ_ATTESTATION."
echo
echo "  The superseded pair must still return v1 (proof they are the old ones):"
echo "    cast call 0xDaEa22D6DCB37FBF1462d6d08ADE40A8fAc05144 'PQ()(address)' --rpc-url $RPC"
echo "    cast call 0xE3de921790d04656F2640fA1eDD75492e911Ffa6 'PQ()(address)' --rpc-url $RPC"
