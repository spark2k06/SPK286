#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_DIR="${SPK286_PHASE8_BUILD_DIR:-$ROOT_DIR/build/phase8-complete}"
if [[ -e "$BUILD_DIR" ]]; then
    echo "PHASE8_CHECK_FAIL: choose a previously absent build directory" >&2
    exit 1
fi
mkdir -p "$BUILD_DIR/logs"
export SPK286_BUILD_DIR="$BUILD_DIR"

run_stage() {
    local stage="$1"
    shift
    echo "PHASE8_STAGE_START $stage"
    "$@" 2>&1 | tee "$BUILD_DIR/logs/$stage.log"
    echo "PHASE8_STAGE_PASS $stage"
}

run_stage focused-8a-iverilog bash scripts/test_units.sh iverilog spk286_biu_hold_lock
run_stage focused-8a-verilator bash scripts/test_units.sh verilator spk286_biu_hold_lock
run_stage focused-xchg-iverilog bash scripts/test_units.sh iverilog spk286_xchg_hold_lock
run_stage focused-xchg-verilator bash scripts/test_units.sh verilator spk286_xchg_hold_lock
run_stage focused-8b-iverilog bash scripts/test_units.sh iverilog spk286_esc_instructions
run_stage focused-8b-verilator bash scripts/test_units.sh verilator spk286_esc_instructions
run_stage focused-decoder-iverilog bash scripts/test_units.sh iverilog spk286_decoder
run_stage focused-decoder-verilator bash scripts/test_units.sh verilator spk286_decoder
run_stage microcode-tests make microcode-test
run_stage microcode-audit make microcode-audit
run_stage lint make lint
run_stage whole-core make unit
run_stage phase8-mutation make phase8-audit
run_stage synthesis make synth-check
run_stage regression make regression

echo "PHASE8_CHECK PASS: focused, microcode, lint, whole-core, mutation, synthesis and regression stages passed"
