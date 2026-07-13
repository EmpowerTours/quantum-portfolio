#!/usr/bin/env bash
#
# One-shot: install the SP1 toolchain + deps on a fresh Ubuntu box, then
# generate the Groth16 (on-chain) proof of the ML-DSA-65 verification and
# print the Solidity fixture.
#
# Intended for a rented cloud box with >=32 GB RAM (the wrap OOMs under ~16 GB).
# Run it from inside this folder:  bash provision.sh
#
# It produces contracts/src/fixtures/groth16-mldsa-fixture.json — copy that back;
# the on-chain deploy (MLDSAAttestation + verify) is done separately on your own
# machine so no keys ever touch the rented box.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

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

echo "==> Generating the Groth16 proof (this pulls the gnark Docker image on first run)"
export SP1_PROVER=cpu
cd "$SCRIPT_DIR/script"
cargo run --release --bin evm -- --system groth16 --input "$SCRIPT_DIR/mldsa_input.json"

echo
echo "======================= GROTH16 FIXTURE ======================="
cat "$SCRIPT_DIR/contracts/src/fixtures/groth16-mldsa-fixture.json"
echo
echo "==============================================================="
echo "Done. Copy the JSON above back to your machine, then destroy this box."
