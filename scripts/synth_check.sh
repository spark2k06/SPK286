#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build}"
REPORT="$BUILD_DIR/reports/yosys_synth_check.log"
mkdir -p "$(dirname "$REPORT")"
cd "$ROOT_DIR"
source scripts/rtl_sources.sh

command -v yosys >/dev/null 2>&1 || {
    echo "yosys is required; run ./scripts/bootstrap.sh" >&2
    exit 1
}

yosys -Q -p "read_verilog -sv ${rtl_sources[*]}; hierarchy -check -top spk286; proc; opt; check -assert; stat" | tee "$REPORT"
yosys -Q -p 'read_verilog -sv rtl/spk286_registers.sv; hierarchy -check -top spk286_registers; proc; opt; check -assert; stat' | tee "$BUILD_DIR/reports/yosys_registers.log"
yosys -Q -p 'read_verilog -sv rtl/spk286_segments.sv; hierarchy -check -top spk286_segments; proc; opt; check -assert; stat' | tee "$BUILD_DIR/reports/yosys_segments.log"
yosys -Q -p 'read_verilog -sv rtl/spk286_fetch.sv; hierarchy -check -top spk286_fetch; proc; opt; check -assert; stat' | tee "$BUILD_DIR/reports/yosys_fetch.log"
yosys -Q -p 'read_verilog -sv rtl/spk286_prefetch_queue.sv; hierarchy -check -top spk286_prefetch_queue; proc; opt; check -assert; stat' | tee "$BUILD_DIR/reports/yosys_prefetch_queue.log"
for module in spk286_microsequencer spk286_decoder spk286_micro_executor spk286_microcode_rom spk286_modrm spk286_effective_address spk286_operand_decode spk286_operand spk286_biu spk286_alu spk286_alu_decode; do
    yosys -Q -p "read_verilog -sv ${rtl_sources[*]}; hierarchy -check -top $module; proc; opt; check -assert; stat" | tee "$BUILD_DIR/reports/yosys_$module.log"
done
# Fully lower/map memories and logic too; proc/check alone is not a synthesis run.
yosys -Q -p "read_verilog -sv ${rtl_sources[*]}; synth -top spk286; check -assert; stat" | tee "$BUILD_DIR/reports/yosys_mapped.log"
echo "SYNTH_CHECK PASS: $REPORT"
