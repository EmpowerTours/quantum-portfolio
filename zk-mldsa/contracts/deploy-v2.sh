#!/usr/bin/env bash
#
# Deploy MLDSAAttestationV2 to Monad mainnet.
#
# RUN THIS IN A REAL TERMINAL WINDOW. Not through Claude Code's `!` prefix and
# not through an agent's shell tool: neither allocates a TTY, so the keystore
# passphrase prompt cannot work there — and the attempt is how a passphrase ends
# up in a conversation transcript. The TTY check below enforces that rather than
# trusting anyone to remember it.
#
# No secret is read, written, echoed or passed as an argument by this script.
# The passphrase goes straight from your terminal into forge. Every value set
# here is public and already on-chain or in the repo.
#
#   cd ~/projects/quantum-portfolio/zk-mldsa/contracts
#   ./deploy-v2.sh              # preflight + simulation, then asks before sending
#   ./deploy-v2.sh --dry-run    # preflight + simulation only, never broadcasts
#
set -euo pipefail
# Deliberately no `set -x`: it would echo every command, and this script runs
# next to a passphrase prompt.

RPC="${RPC:-https://rpc.monad.xyz}"
CHAIN_ID=143

# --- public parameters -------------------------------------------------------
# SP1 Groth16 verifier on Monad mainnet, read from the v1 MLDSAAttestation
# deployment (broadcast/DeployMLDSAAttestation.s.sol/143/run-latest.json).
export SP1_VERIFIER="${SP1_VERIFIER:-0x7DA83eC4af493081500Ecd36d1a72c23F8fc2abd}"
# SHA-256 of keys/pq.pub — the identity pinned as the genesis authorised key.
export AGENT_PK_HASH="${AGENT_PK_HASH:-0xac0b2aea57e0d9188717e9dada2042a60e2cae45bff90eccde9c1be13f5702ad}"
# Recovery authority. May only ADD a key, only after the delay, and only if the
# agent does not veto. It can never revoke and never attest.
export GUARDIAN="${GUARDIAN:-0x05d1599622915050C4981816ef5E8d51F53dbc7D}"
export RECOVERY_DELAY="${RECOVERY_DELAY:-604800}"   # 7 days

DEPLOYER="${DEPLOYER:-0x8dF64bACf6b70F7787f8d14429b258B3fF958ec1}"
ACCOUNT="${ACCOUNT:-deployer}"   # forge keystore account name

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")"

die() { printf '\nREFUSING: %s\n' "$1" >&2; exit 1; }
say() { printf '  %s\n' "$1"; }

# --- 0. a real terminal ------------------------------------------------------
# The whole point of the keystore is that the key never enters the process
# environment. That only holds if forge can prompt, which needs a TTY.
if [ ! -t 0 ] || [ ! -t 1 ]; then
    die "no TTY. Run this in a terminal window, not through Claude Code's \`!\`
          prefix or an agent shell tool — the passphrase prompt cannot work
          there, and trying is how a passphrase ends up in a transcript."
fi

# A raw key in the environment defeats the keystore and lands in \`ps\` output
# and shell history. Allowed, but only if you say so deliberately.
if [ -n "${DEPLOYER_PRIVATE_KEY:-}" ] && [ "${ALLOW_ENV_KEY:-0}" != "1" ]; then
    die "DEPLOYER_PRIVATE_KEY is set in this environment. Prefer the encrypted
          keystore (--account $ACCOUNT). To override deliberately:
              ALLOW_ENV_KEY=1 ./deploy-v2.sh"
fi

command -v forge >/dev/null || die "forge not on PATH"
command -v cast  >/dev/null || die "cast not on PATH"

echo
echo "=== preflight ==============================================="

# --- 1. the chain is the one we think ---------------------------------------
got_chain=$(cast chain-id --rpc-url "$RPC")
[ "$got_chain" = "$CHAIN_ID" ] || die "RPC reports chain $got_chain, expected $CHAIN_ID (Monad mainnet)"
say "chain id           $got_chain"

# --- 2. the verifier exists --------------------------------------------------
# A verifier with no code bricks attest() uncatchably. The contract checks this
# too; catching it here costs nothing and saves a failed broadcast.
size=$(cast codesize "$SP1_VERIFIER" --rpc-url "$RPC")
[ "$size" -gt 0 ] || die "SP1_VERIFIER $SP1_VERIFIER has no code"
say "SP1 verifier       $SP1_VERIFIER ($size bytes)"

# --- 3. the guardian is not the deployer, and is not a typo ------------------
if [ "${GUARDIAN,,}" = "${DEPLOYER,,}" ]; then
    die "GUARDIAN is the deployer key. One compromise would then reach both."
fi
g_code=$(cast codesize "$GUARDIAN" --rpc-url "$RPC")
g_bal=$(cast balance  "$GUARDIAN" --rpc-url "$RPC")
g_nonce=$(cast nonce  "$GUARDIAN" --rpc-url "$RPC")
if [ "$g_code" -eq 0 ] && [ "$g_bal" = "0" ] && [ "$g_nonce" -eq 0 ]; then
    die "GUARDIAN $GUARDIAN has no code, no balance and no nonce — typo?
          A mistyped guardian deploys cleanly and is discovered on the day
          recovery is needed."
fi
say "guardian           $GUARDIAN (code=$g_code nonce=$g_nonce)"
if [ "$g_code" -eq 0 ]; then
    say "                   ^ EOA, not a multisig. The delay only bounds the"
    say "                     damage if somebody WATCHES for RecoveryProposed."
fi

# --- 4. the fixture proves a signature by the key we are pinning -------------
# Deploying against a fixture signed by a different key produces a contract
# that reverts UnknownSigner on every call, forever. This is the check whose
# absence shipped a fixture for the lost 8a1b08d1... identity.
fixture="src/fixtures/groth16-mldsa-fixture.json"
[ -f "$fixture" ] || die "fixture not found at $fixture"
fx_pk=$(python3 -c "
import json,sys
d=json.load(open('$fixture')); pv=d['publicValues'][2:]
print('0x'+pv[64:128] if len(pv)==128 else 'BADLEN')
")
[ "$fx_pk" != "BADLEN" ] || die "fixture publicValues is not 64 bytes — stale single-field layout"
if [ "${fx_pk,,}" != "${AGENT_PK_HASH,,}" ]; then
    die "fixture was signed by $fx_pk but AGENT_PK_HASH is $AGENT_PK_HASH.
          Deploying this would revert UnknownSigner on every call."
fi
say "fixture pkHash     $fx_pk (matches AGENT_PK_HASH)"

# --- 5. the deployer can pay -------------------------------------------------
bal=$(cast balance "$DEPLOYER" --rpc-url "$RPC")
say "deployer           $DEPLOYER"
say "deployer balance   $(cast from-wei "$bal") MON"
# ~0.45 MON at 202 gwei when this was written; refuse well below that.
if [ "$(cast from-wei "$bal" | cut -d. -f1)" -lt 2 ]; then
    die "deployer balance is under 2 MON; the deploy needs roughly 0.45 MON"
fi

echo
echo "=== simulation =============================================="
# No wallet needed: nothing is signed. The post-deploy isValidProof inside the
# script runs the REAL Groth16 proof against the REAL verifier in forked state,
# so a pass here means the deployed contract will actually attest.
forge script script/DeployMLDSAAttestationV2.s.sol \
    --rpc-url "$RPC" --sender "$DEPLOYER"

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "--dry-run: stopping here. Nothing was broadcast."
    exit 0
fi

# --- 6. the human gate -------------------------------------------------------
cat <<EOF

=== about to BROADCAST to Monad mainnet =====================

  MLDSAAttestationV2, immutable, permanent.
    verifier       $SP1_VERIFIER
    agentPkHash    $AGENT_PK_HASH
    guardian       $GUARDIAN
    recoveryDelay  $RECOVERY_DELAY seconds
    from           $DEPLOYER (keystore account '$ACCOUNT')

  This is step 1 of 3. PQ() is immutable on both executors, so
  UniswapRoutingVault and MorphoSupplyAdapter must be redeployed against
  the new address afterwards. Until then the live stack still uses v1
  0xb0aADaFe68647578520E988b4444e556c300b4Da and nothing has changed in
  production.

  forge will prompt for the keystore passphrase. Nothing echoes it.

EOF
printf "Type DEPLOY to broadcast, anything else to abort: "
read -r answer
[ "$answer" = "DEPLOY" ] || { echo "aborted; nothing was sent."; exit 1; }

echo
echo "=== broadcasting ============================================"
if [ -n "${DEPLOYER_PRIVATE_KEY:-}" ]; then
    # Deliberate override (ALLOW_ENV_KEY=1). forge reads it from the env; it is
    # never passed as an argument, so it stays out of `ps` and the logs.
    forge script script/DeployMLDSAAttestationV2.s.sol \
        --rpc-url "$RPC" --broadcast
else
    forge script script/DeployMLDSAAttestationV2.s.sol \
        --rpc-url "$RPC" --account "$ACCOUNT" --sender "$DEPLOYER" --broadcast
fi

# --- 7. hand over everything Monadscan verification needs --------------------
# One script, one CREATE, one transaction — verification is per-contract, so
# keeping each deploy to a single contract is what makes this step smooth. The
# constructor args are re-encoded here rather than pasted from a note, so they
# cannot drift from what was actually deployed.
ADDR=$(python3 -c "
import json
d=json.load(open('broadcast/DeployMLDSAAttestationV2.s.sol/$CHAIN_ID/run-latest.json'))
print(next(t['contractAddress'] for t in d['transactions'] if t['transactionType']=='CREATE'))
" 2>/dev/null || true)

CTOR_ARGS=$(cast abi-encode "c(address,bytes32,bytes32,address,uint64)" \
    "$SP1_VERIFIER" \
    "$(cast call "$ADDR" 'mldsaProgramVKey()(bytes32)' --rpc-url "$RPC")" \
    "$AGENT_PK_HASH" "$GUARDIAN" "$RECOVERY_DELAY")

echo
echo "=== deployed ================================================"
echo "  MLDSAAttestationV2   $ADDR"
echo
echo "  Confirm it independently:"
echo "    cast call $ADDR 'isAgentPk(bytes32)(bool)' $AGENT_PK_HASH --rpc-url $RPC"
echo "    cast call $ADDR 'guardian()(address)' --rpc-url $RPC"
echo "    cast call $ADDR 'agentPkCount()(uint256)' --rpc-url $RPC"
echo
echo "=== verify on Monadscan ====================================="
echo "  Constructor args (ABI-encoded, read back from the live contract):"
echo "    $CTOR_ARGS"
echo
if [ -n "${VERIFIER_URL:-}" ] && [ -n "${ETHERSCAN_API_KEY:-}" ]; then
    echo "  VERIFIER_URL set — verifying now."
    # Per the round-1 pattern: no --chain flag; the chainid in --verifier-url
    # is what routes it.
    forge verify-contract "$ADDR" \
        src/MLDSAAttestationV2.sol:MLDSAAttestationV2 \
        --constructor-args "$CTOR_ARGS" \
        --verifier etherscan \
        --verifier-url "$VERIFIER_URL" \
        --etherscan-api-key "$ETHERSCAN_API_KEY" \
        --watch
else
    echo "  VERIFIER_URL / ETHERSCAN_API_KEY not set. Run this yourself:"
    echo
    echo "    forge verify-contract $ADDR \\"
    echo "      src/MLDSAAttestationV2.sol:MLDSAAttestationV2 \\"
    echo "      --constructor-args $CTOR_ARGS \\"
    echo "      --verifier etherscan --verifier-url \$VERIFIER_URL \\"
    echo "      --etherscan-api-key \$ETHERSCAN_API_KEY --watch"
    echo
    echo "  (No --chain flag: the chainid inside --verifier-url routes it.)"
fi

echo
echo "=== next ===================================================="
echo "  Do these ONE AT A TIME, verifying each on Monadscan before the next."
echo "  Each is its own script and its own single CREATE transaction."
echo
echo "  2. UniswapRoutingVault   contracts/script/DeployUniswapRoutingVault.s.sol"
echo "  3. MorphoSupplyAdapter   contracts/script/DeployMorphoSupplyAdapter.s.sol"
echo "     Both need PQ = $ADDR (their PQ() is immutable)."
echo
echo "  Then confirm the gate is real — PQ() must return the new address on the"
echo "  new executors and REVERT on the superseded ones:"
echo "    cast call <executor> 'PQ()(address)' --rpc-url $RPC"
