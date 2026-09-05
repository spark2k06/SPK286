#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build}"
REPORT="$BUILD_DIR/reports/yosys_synth_check.log"
mkdir -p "$(dirname "$REPORT")"
cd "$ROOT_DIR"

command -v yosys >/dev/null 2>&1 || {
    echo "yosys is required; run ./scripts/bootstrap.sh" >&2
    exit 1
}

yosys -Q -p 'read_verilog -sv rtl/spk286.sv; hierarchy -check -top spk286; proc; opt; check; stat' | tee "$REPORT"
echo "SYNTH_CHECK PASS: $REPORT"
