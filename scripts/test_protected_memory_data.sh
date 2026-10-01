#!/usr/bin/env bash
# Exact data-path proof and affected PM banks; no whole-project regression.
set -euo pipefail
ulimit -c 0
root=$(cd "$(dirname "$0")/.." && pwd)
output=$(realpath -m "${1:-$root/build/protected-memory-data}")
[[ $# -le 1 && ! -e "$output" ]]
cd "$root"
mkdir -p "$output"
python3 scripts/prove_protected_memory_data.py "$output/formal" | tee "$output/formal-result.log"
source scripts/rtl_sources.sh
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
sha256sum rtl/spk286.sv rtl/spk286_operand.sv rtl/spk286_micro_executor.sv \
  scripts/prove_protected_memory_data.py scripts/test_protected_memory_data.sh > "$output/sources.sha256"
echo PROTECTED_MEMORY_DATA_DIRECTED_PASS
