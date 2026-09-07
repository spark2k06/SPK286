#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build}"
OBJ_DIR="$BUILD_DIR/verilator/obj_dir"
mkdir -p "$OBJ_DIR"

cd "$ROOT_DIR"
source scripts/rtl_sources.sh
command -v verilator >/dev/null 2>&1 || {
    echo "verilator is required; run ./scripts/bootstrap.sh" >&2
    exit 1
}

verilator --cc --exe --build --trace --Wall \
    --language 1800-2012 --top-module spk286 \
    --Mdir "$OBJ_DIR" -I"$ROOT_DIR/rtl" \
    -CFLAGS "-std=c++17 -Wall -Wextra" \
    -o spk286_smoke "${rtl_sources[@]}" "$ROOT_DIR/sim/verilator/reset_smoke.cpp" \
    "$ROOT_DIR/sim/verilator/state_vector.cpp" \
    "$ROOT_DIR/sim/verilator/singlestep.cpp"

echo "VERILATOR BUILD PASS: $OBJ_DIR/spk286_smoke"
