#!/usr/bin/env bash
# Exact combinational proofs and four affected PM banks, no full regression.
set -euo pipefail
ulimit -c 0
root=$(cd "$(dirname "$0")/.." && pwd)
output=$(realpath -m "${1:-$root/build/descriptor-fault-timing}")
[[ $# -le 1 && ! -e "$output" ]]
cd "$root"
mkdir -p "$output"
python3 scripts/prove_descriptor_word_select.py "$output/descriptor-formal" | tee "$output/descriptor-formal-result.log"
python3 scripts/prove_fault_error_classification.py "$output/fault-formal" | tee "$output/fault-formal-result.log"
source scripts/rtl_sources.sh
sha256sum "${rtl_sources[@]}" scripts/prove_descriptor_word_select.py scripts/prove_fault_error_classification.py \
  scripts/test_descriptor_fault_timing.sh > "$output/sources.sha256"
for profile in base pcat; do
  defines=()
  if [[ $profile == pcat ]]; then
    defines=(-DSPK286_P01_FAST_MEMORY_START -DSPK286_P02_FETCH_CHAIN
             -DSPK286_P05_PARALLEL_LIMIT_CHECK -DSPK286_P06_EARLY_MEMORY_ADDRESS)
  fi
  verilator --lint-only --language 1800-2012 --Wall --top-module spk286 \
    -Irtl "${defines[@]}" "${rtl_sources[@]}" > "$output/${profile}-lint.log" 2>&1
  for unit in spk286_call_gate_accessed spk286_protected_system spk286_double_fault_cpu spk286_protected_task_ldt; do
    top=${unit}_tb
    stem=$output/$profile/$unit
    mkdir -p "$stem"
    iverilog -g2012 -Irtl -Isim/unit "${defines[@]}" -s "$top" -o "$stem/test.vvp" \
      "${rtl_sources[@]}" "sim/unit/$top.sv" > "$stem/iverilog-build.log" 2>&1
    vvp "$stem/test.vvp" | tee "$stem/iverilog-run.log"
    verilator --binary --build-jobs "${SPK286_BUILD_JOBS:-2}" --timing --assert \
      --language 1800-2012 --top-module "$top" --Mdir "$stem/verilator" \
      -Irtl -Isim/unit "${defines[@]}" -o directed \
      "${rtl_sources[@]}" "sim/unit/$top.sv" > "$stem/verilator-build.log" 2>&1
    "$stem/verilator/directed" | tee "$stem/verilator-run.log"
    grep ' PASS:' "$stem/iverilog-run.log" > "$stem/iverilog-result.txt"
    grep ' PASS:' "$stem/verilator-run.log" > "$stem/verilator-result.txt"
    cmp "$stem/iverilog-result.txt" "$stem/verilator-result.txt"
  done
done
sha256sum --check "$output/sources.sha256" > "$output/sources-verified.log"
echo DESCRIPTOR_FAULT_TIMING_DIRECTED_PASS
