#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build}"
LOG_DIR="$BUILD_DIR/failures/phase0-negative"
mkdir -p "$LOG_DIR"

"$ROOT_DIR/scripts/build_verilator.sh" >/dev/null
"$ROOT_DIR/scripts/test_iverilog.sh" >/dev/null

run_expect_failure() {
    local log_file="$1"
    shift
    local status=0
    "$@" >"$log_file" 2>&1 || status=$?
    cat "$log_file"
    if ((status == 0)); then
        echo "Expected command to fail but it returned zero: $*" >&2
        exit 1
    fi
}

run_expect_failure "$LOG_DIR/verilator.log" \
    "$BUILD_DIR/verilator/obj_dir/spk286_smoke" --expected-fetch 0x000000
run_expect_failure "$LOG_DIR/iverilog.log" \
    vvp "$BUILD_DIR/iverilog/spk286_reset_tb.vvp" +expected_fetch=000000

echo "FAILURE_PATH PASS: both simulators rejected an incorrect expectation"
