#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build}"
OBJ_DIR="$BUILD_DIR/verilator/timing-policy-init"
mkdir -p "$OBJ_DIR"

cd "$ROOT_DIR"
source scripts/rtl_sources.sh

verilator --cc --exe --build --build-jobs "${SPK286_BUILD_JOBS:-1}" --Wall \
    --language 1800-2012 --top-module spk286 \
    --Mdir "$OBJ_DIR" -Irtl \
    -CFLAGS "-std=c++17 -Wall -Wextra -I$ROOT_DIR/sim/verilator" \
    -o timing_policy_init "${rtl_sources[@]}" \
    "$ROOT_DIR/sim/verilator/timing_policy_init.cpp" >"$OBJ_DIR/build.log" 2>&1

"$OBJ_DIR/timing_policy_init"
