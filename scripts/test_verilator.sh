#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build}"
TRACE_ARGS=()

if [[ "${1:-}" == "--trace" ]]; then
    mkdir -p "$BUILD_DIR/traces"
    TRACE_ARGS=(--trace "$BUILD_DIR/traces/reset_verilator.vcd")
    shift
fi

if (($# != 0)); then
    echo "Usage: $0 [--trace]" >&2
    exit 2
fi

"$ROOT_DIR/scripts/build_verilator.sh"
"$BUILD_DIR/verilator/obj_dir/spk286_smoke" "${TRACE_ARGS[@]}"
