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

yosys -Q -p 'read_verilog -sv rtl/*.sv; hierarchy -check -top spk286; proc; opt; check -assert; stat' | tee "$REPORT"
yosys -Q -p 'read_verilog -sv rtl/spk286_registers.sv; hierarchy -check -top spk286_registers; proc; opt; check -assert; stat' | tee "$BUILD_DIR/reports/yosys_registers.log"
yosys -Q -p 'read_verilog -sv rtl/spk286_segments.sv; hierarchy -check -top spk286_segments; proc; opt; check -assert; stat' | tee "$BUILD_DIR/reports/yosys_segments.log"
yosys -Q -p 'read_verilog -sv rtl/spk286_fetch.sv; hierarchy -check -top spk286_fetch; proc; opt; check -assert; stat' | tee "$BUILD_DIR/reports/yosys_fetch.log"
yosys -Q -p 'read_verilog -sv rtl/spk286_prefetch_queue.sv; hierarchy -check -top spk286_prefetch_queue; proc; opt; check -assert; stat' | tee "$BUILD_DIR/reports/yosys_prefetch_queue.log"
echo "SYNTH_CHECK PASS: $REPORT"
