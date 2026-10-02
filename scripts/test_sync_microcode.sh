#!/usr/bin/env bash
# Directed ROM sequencing and representative CPU banks; no full regression.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output=$(realpath -m "${1:-$root/build/sync-microcode}")
[[ $# -le 1 && ! -e "$output" ]]
cd "$root"; mkdir -p "$output"
python3 scripts/prove_sync_microcode.py "$output/formal" | tee "$output/formal-result.log"
python3 -m unittest discover -s tests -p 'test_microcode*.py' -v > "$output/compiler-tests.log" 2>&1
python3 -m tools.microcode.audit_microcode --output "$output/compiler-audit" > "$output/compiler-audit.log" 2>&1
source scripts/rtl_sources.sh
sha256sum "${rtl_sources[@]}" tools/microcode/compile_microcode.py scripts/prove_sync_microcode.py \
  scripts/test_sync_microcode.sh sim/unit/spk286_sync_microcode_tb.sv sim/unit/spk286_microsequencer_tb.sv > "$output/sources.sha256"
rom_sources=(microcode/generated/spk286_microcode_pkg.sv microcode/generated/spk286_microcode_rom.sv microcode/generated/spk286_microcode_sync_rom.sv rtl/spk286_microsequencer.sv)
for unit in spk286_sync_microcode spk286_microsequencer spk286_microcode_rom; do
  top=${unit}_tb; stem=$output/$unit; mkdir -p "$stem"
  reference=()
  [[ $unit != spk286_sync_microcode ]] || reference=("$output/formal/reference_microsequencer.sv")
  iverilog -g2012 -s "$top" -o "$stem/test.vvp" "${rom_sources[@]}" "${reference[@]}" "sim/unit/$top.sv" > "$stem/iverilog-build.log" 2>&1
  vvp "$stem/test.vvp" | tee "$stem/iverilog-run.log"
  verilator --binary --build-jobs 2 --timing --assert --Wall --top-module "$top" --Mdir "$stem/obj" \
    -o directed "${rom_sources[@]}" "${reference[@]}" "sim/unit/$top.sv" > "$stem/verilator-build.log" 2>&1
  "$stem/obj/directed" | tee "$stem/verilator-run.log"
  grep ' PASS:' "$stem/iverilog-run.log" > "$stem/iverilog-result.txt"
  grep ' PASS:' "$stem/verilator-run.log" > "$stem/verilator-result.txt"
  cmp "$stem/iverilog-result.txt" "$stem/verilator-result.txt"
done
for profile in base pcat; do
  defines=()
  if [[ $profile == pcat ]]; then
    defines=(-DSPK286_P01_FAST_MEMORY_START -DSPK286_P02_FETCH_CHAIN -DSPK286_P05_PARALLEL_LIMIT_CHECK -DSPK286_P06_EARLY_MEMORY_ADDRESS -DSPK286_P07_SYNC_MICROCODE)
  fi
  verilator --lint-only --Wall --top-module spk286 -Irtl "${defines[@]}" "${rtl_sources[@]}" > "$output/$profile-lint.log" 2>&1
  for unit in spk286_microcode_execution spk286_event_streams spk286_call_gate_accessed spk286_loadall_integration spk286_double_fault_cpu; do
    top=${unit}_tb; stem=$output/$profile/$unit; mkdir -p "$stem"
    run_args=()
    if [[ $unit == spk286_event_streams ]]; then
      python3 -m tools.event_streams --output "$stem/event-streams.txt" > "$stem/vector-generation.log"
      run_args=("+stream_vectors=$stem/event-streams.txt")
    fi
    iverilog -g2012 -Irtl -Isim/unit "${defines[@]}" -s "$top" -o "$stem/test.vvp" "${rtl_sources[@]}" "sim/unit/$top.sv" > "$stem/iverilog-build.log" 2>&1
    vvp "$stem/test.vvp" "${run_args[@]}" | tee "$stem/iverilog-run.log"
    verilator --binary --build-jobs 2 --timing --assert --top-module "$top" --Mdir "$stem/obj" \
      -Irtl -Isim/unit "${defines[@]}" -o directed "${rtl_sources[@]}" "sim/unit/$top.sv" > "$stem/verilator-build.log" 2>&1
    "$stem/obj/directed" "${run_args[@]}" | tee "$stem/verilator-run.log"
    grep ' PASS:' "$stem/iverilog-run.log" > "$stem/iverilog-result.txt"
    grep ' PASS:' "$stem/verilator-run.log" > "$stem/verilator-result.txt"
    cmp "$stem/iverilog-result.txt" "$stem/verilator-result.txt"
  done
done
sha256sum --check "$output/sources.sha256" > "$output/sources-verified.log"
echo SYNC_MICROCODE_DIRECTED_PASS
