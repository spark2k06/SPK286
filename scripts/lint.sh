#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source scripts/rtl_sources.sh

command -v verilator >/dev/null 2>&1 || {
    echo "verilator is required; run ./scripts/bootstrap.sh" >&2
    exit 1
}

verilator --lint-only --language 1800-2012 --Wall \
    --top-module spk286 -Irtl "${rtl_sources[@]}"
verilator --lint-only --language 1800-2012 --Wall \
    --top-module spk286_registers -Irtl rtl/spk286_registers.sv
verilator --lint-only --language 1800-2012 --Wall \
    --top-module spk286_segments -Irtl rtl/spk286_segments.sv
verilator --lint-only --language 1800-2012 --Wall \
    --top-module spk286_fetch -Irtl rtl/spk286_fetch.sv
verilator --lint-only --language 1800-2012 --Wall \
    --top-module spk286_prefetch_queue -Irtl rtl/spk286_prefetch_queue.sv
for module in spk286_microsequencer spk286_decoder spk286_micro_executor spk286_microcode_rom spk286_modrm spk286_effective_address spk286_operand_decode spk286_operand spk286_biu spk286_alu spk286_alu_decode spk286_stack spk286_condition spk286_control_decode spk286_events spk286_selector spk286_descriptor spk286_protected_state; do
    verilator --lint-only --language 1800-2012 --Wall \
        --top-module "$module" -Irtl "${rtl_sources[@]}"
done
echo "LINT PASS"
