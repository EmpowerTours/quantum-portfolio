#!/usr/bin/env bash
#
# Prove BOTH legs of the 2026-08-25 re-run: the routing order and the supply
# order, each against MLDSAAttestationV2.
#
# `provision.sh` proves exactly one input and writes to a FIXED fixture path,
# so running it twice silently overwrites the first proof with the second. This
# script proves both, files each fixture under its own name, and validates each
# one WHILE THE BOX STILL EXISTS — discovering a bad fixture after you destroy
# it means renting another.
#
# No secret key material is read or written. The guest input is
# (public key, message, signature) — all public — which is what makes it safe
# to carry to a rented box. The deploy and the on-chain calls happen on your
# own machine.
#
# Two ways to run it:
#
#   A. RENTED BOX (>=32 GB RAM; the Groth16 wrap OOMs under ~16 GB).
#      tar the repo across, then:
#        bash zk-mldsa/prove-both.sh
#
#   B. SUCCINCT PROVER NETWORK — no box at all. `evm.rs` uses
#      `ProverClient::from_env()` with dotenv, so set these in zk-mldsa/.env
#      and run the same script on any machine:
#        SP1_PROVER=network
#        NETWORK_PRIVATE_KEY=0x...
#      Pass --skip-setup to leave the local toolchain alone.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

LEGS=(route supply)
SKIP_SETUP=0
[ "${1:-}" = "--skip-setup" ] && SKIP_SETUP=1

die() { printf '\nREFUSING: %s\n' "$1" >&2; exit 1; }

# --- inputs must exist BEFORE any setup cost is incurred --------------------
for leg in "${LEGS[@]}"; do
    [ -f "$SCRIPT_DIR/mldsa_input_${leg}.json" ] \
        || die "missing mldsa_input_${leg}.json — generate it on your own
          machine with zk-mldsa/export_mldsa_input.py and copy it across."
done

if [ "$SKIP_SETUP" -eq 0 ]; then
    echo "==> RAM check (need >=32 GB for the Groth16 wrap)"
    free -h | head -2

    SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

    echo "==> apt deps"
    $SUDO apt-get update -y
    $SUDO apt-get install -y curl git build-essential pkg-config libssl-dev unzip ca-certificates

    echo "==> Docker (gnark Groth16 prover runs in a container)"
    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        $SUDO sh /tmp/get-docker.sh
    fi
    $SUDO systemctl enable --now docker 2>/dev/null || $SUDO service docker start 2>/dev/null || true

    echo "==> Rust"
    if ! command -v cargo >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh
        sh /tmp/rustup.sh -y --default-toolchain stable
    fi
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"

    echo "==> protoc"
    PROTOC_VER=28.3
    curl -fsSL -o /tmp/protoc.zip \
      "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VER}/protoc-${PROTOC_VER}-linux-x86_64.zip"
    mkdir -p "$HOME/.local/protoc"
    unzip -o -q /tmp/protoc.zip -d "$HOME/.local/protoc"
    export PROTOC="$HOME/.local/protoc/bin/protoc"

    echo "==> SP1 toolchain (sp1up)"
    if [ ! -x "$HOME/.sp1/bin/sp1up" ]; then
        curl -fsSL https://sp1up.succinct.xyz -o /tmp/sp1up.sh
        bash /tmp/sp1up.sh
    fi
    export PATH="$HOME/.sp1/bin:$PATH"
    "$HOME/.sp1/bin/sp1up"
fi

# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
export PATH="$HOME/.sp1/bin:$PATH"
[ -n "${SP1_PROVER:-}" ] || export SP1_PROVER=cpu
echo "==> SP1_PROVER=$SP1_PROVER"

FIXDIR="$SCRIPT_DIR/contracts/src/fixtures"
DEFAULT_FIXTURE="$FIXDIR/groth16-mldsa-fixture.json"
mkdir -p "$FIXDIR"

# ============================ THE VKEY GATE =================================
# Prove NOTHING until the guest this box builds is the guest the chain pins.
#
# `mldsaProgramVKey` is an immutable hash of the compiled guest ELF, and
# attest() reverts on any other value. So a vkey mismatch does not degrade the
# proof, it voids it — and the only cheap moment to learn that is BEFORE an
# hour of Groth16 wrapping, not after.
#
# This is not hypothetical. On 2026-08-25 this script proved a full route leg
# on a rented box against vkey 0x00aa9611 while the chain pinned 0x00ed29f3,
# because a four-line doc comment in program/src/main.rs (vs three) shifted
# every line below `.expect(...)`, and `core::panic::Location{file,line,col}`
# is embedded in the binary as static data. The proof was worthless and the
# box time was spent. The earlier version of this script validated each
# fixture's orderHash and pkHash and merely PRINTED its vkey, which is exactly
# why a fixture that could never verify passed its own validation.
EXPECTED_VKEY="${EXPECTED_VKEY:-0x00ed29f3eb27b863b25c2619776ecc56c8c84e90b7da27250c8317cc2758cbd5}"
ATTESTATION="${ATTESTATION:-0xFeEf24A5dBF43E9dE8AC0d0EaB0f0141E980A52c}"
RPC="${RPC:-https://rpc.monad.xyz}"

# protoc is needed to build the vkey/evm binaries; the setup step exports it,
# but --skip-setup may not have.
[ -n "${PROTOC:-}" ] || { [ -x "$HOME/.local/protoc/bin/protoc" ] && export PROTOC="$HOME/.local/protoc/bin/protoc"; }

echo
echo "==> Vkey gate: building the guest and checking it against the chain"
BUILT_VKEY=$( cd "$SCRIPT_DIR/script" && cargo run --release --bin vkey 2>/dev/null | grep -Eo '^0x[0-9a-f]{64}' | tail -1 )
[ -n "$BUILT_VKEY" ] || die "could not compute the guest vkey. Without it this
      script cannot tell whether a proof would verify, and proving blind is how
      the 2026-08-25 box time was wasted."
echo "    built    $BUILT_VKEY"
echo "    expected $EXPECTED_VKEY"

if [ "${BUILT_VKEY,,}" != "${EXPECTED_VKEY,,}" ]; then
    die "GUEST MISMATCH — every proof from this tree would revert in attest().
      built    $BUILT_VKEY
      expected $EXPECTED_VKEY
      The guest source differs from what the chain pins. Note that a COMMENT is
      enough to do this: line numbers reach the binary through panic Location
      metadata. Check \`git status\` and \`git log\` on program/ and lib/,
      and see verify_claims.py's guest-input digest, which pins all 16 build
      inputs. Nothing here is worth proving until these match."
fi

# The constant above can itself go stale. If cast and a network are available,
# confirm it still equals what the attestation actually pins.
if command -v cast >/dev/null 2>&1; then
    ONCHAIN=$(cast call "$ATTESTATION" 'mldsaProgramVKey()(bytes32)' --rpc-url "$RPC" 2>/dev/null || true)
    if [ -n "$ONCHAIN" ]; then
        [ "${ONCHAIN,,}" = "${EXPECTED_VKEY,,}" ] || die "the pinned EXPECTED_VKEY is
      stale: $ATTESTATION reports $ONCHAIN. Update it deliberately."
        echo "    on-chain $ONCHAIN  (confirmed against $ATTESTATION)"
    else
        echo "    on-chain check skipped (no RPC reachable) — constant not re-confirmed"
    fi
else
    echo "    on-chain check skipped (no cast on this box) — constant not re-confirmed"
fi
echo "==> Vkey gate passed. Proving is worth the time."

for leg in "${LEGS[@]}"; do
    IN="$SCRIPT_DIR/mldsa_input_${leg}.json"
    OUT="$FIXDIR/groth16-mldsa-${leg}.json"

    echo
    echo "==================================================================="
    echo "==> Proving the ${leg} leg  (this pulls the gnark image on first run)"
    echo "==================================================================="
    # The binary always writes to the same path, so move it aside immediately.
    rm -f "$DEFAULT_FIXTURE"
    ( cd "$SCRIPT_DIR/script" && cargo run --release --bin evm -- --system groth16 --input "$IN" )
    [ -f "$DEFAULT_FIXTURE" ] || die "the ${leg} run produced no fixture"
    mv "$DEFAULT_FIXTURE" "$OUT"
    echo "==> wrote $OUT"

    # Validate NOW, against this leg's own input. These are exactly the three
    # ways the original fixture was unusable: a 32-byte single-field
    # publicValues, a stale vkey, and a signer that is not the pinned key.
    EXPECTED_PKHASH=$(python3 -c "
import json,hashlib
d=json.load(open('$IN'))
print(hashlib.sha256(bytes.fromhex(d['pk_hex'])).hexdigest())")
    EXPECTED_ORDER=$(python3 -c "
import json; print(json.load(open('$IN'))['digest'])")

    python3 - "$OUT" "$EXPECTED_PKHASH" "$EXPECTED_ORDER" "$leg" <<'PYEOF'
import json, sys
fixture, want_pk, want_order, leg = sys.argv[1:5]
d = json.load(open(fixture))
pv = d["publicValues"][2:]
ok = True
if len(pv) != 128:
    print(f"  FAIL publicValues is {len(pv)//2} bytes, expected 64 "
          f"(orderHash + pkHash). Stale single-field guest?")
    ok = False
else:
    order, pk = pv[:64], pv[64:]
    print(f"  [{leg}] orderHash {order}  "
          f"{'OK' if order == want_order else 'FAIL expected ' + want_order}")
    print(f"  [{leg}] pkHash    {pk}  "
          f"{'OK' if pk == want_pk else 'FAIL expected ' + want_pk}")
    ok = ok and order == want_order and pk == want_pk
print(f"  [{leg}] vkey      {d['vkey']}")
print(f"  [{leg}] proof     {(len(d['proof']) - 2) // 2} bytes")
if not ok:
    print(f"\n  *** {leg.upper()} FIXTURE IS NOT USABLE — do NOT destroy this box. ***")
    sys.exit(1)
PYEOF
done

# --- both legs must share a vkey, or one of them was built from stale code ---
python3 - "$FIXDIR" <<'PYEOF'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
vkeys = {leg: json.load(open(d / f"groth16-mldsa-{leg}.json"))["vkey"]
         for leg in ("route", "supply")}
if len(set(vkeys.values())) != 1:
    print(f"\n  *** vkey MISMATCH between legs: {vkeys} ***")
    print("  The two proofs were built from different guest binaries. The")
    print("  attestation pins ONE vkey, so at most one of these can verify.")
    sys.exit(1)
print(f"\n  Both legs share vkey {next(iter(vkeys.values()))}")
PYEOF

echo
echo "======================= ROUTE FIXTURE ========================="
cat "$FIXDIR/groth16-mldsa-route.json"
echo
echo "======================= SUPPLY FIXTURE ========================"
cat "$FIXDIR/groth16-mldsa-supply.json"
echo
echo "==============================================================="
echo "Both fixtures are valid. Copy them back to"
echo "  zk-mldsa/contracts/src/fixtures/"
echo "then DESTROY THIS BOX (it bills by the hour)."
echo
echo "The vkey was checked against the chain BEFORE proving, not after:"
echo "  $EXPECTED_VKEY"
