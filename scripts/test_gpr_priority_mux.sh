#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output=$(realpath -m "${1:-$root/build/gpr-priority-mux}")
[[ $# -le 1 && ! -e "$output" ]]
cd "$root";mkdir -p "$output"
python3 scripts/prove_gpr_priority_mux.py "$output/formal" | tee "$output/formal-result.log"
source scripts/rtl_sources.sh
python3 -m tools.stack_frame_vectors --output "$output/stack-frame-vectors.txt"
sha256sum "${rtl_sources[@]}" scripts/prove_gpr_priority_mux.py scripts/test_gpr_priority_mux.sh > "$output/sources.sha256"
for profile in base pcat;do
 defines=()
 if [[ $profile == pcat ]];then
  defines=(-DSPK286_P01_FAST_MEMORY_START -DSPK286_P02_FETCH_CHAIN -DSPK286_P05_PARALLEL_LIMIT_CHECK -DSPK286_P06_EARLY_MEMORY_ADDRESS)
 fi
 verilator --lint-only --Wall --top-module spk286 -Irtl "${defines[@]}" "${rtl_sources[@]}" > "$output/$profile-lint.log" 2>&1
 for unit in spk286_register_execution spk286_stack_frame_instructions spk286_outer_return_sp;do
  top=${unit}_tb;stem=$output/$profile/$unit;mkdir -p "$stem"
  args=()
  if [[ $unit == spk286_stack_frame_instructions ]];then args=(+instruction_vectors="$output/stack-frame-vectors.txt");fi
  iverilog -g2012 -Irtl -Isim/unit "${defines[@]}" -s "$top" -o "$stem/test.vvp" "${rtl_sources[@]}" "sim/unit/$top.sv" > "$stem/iverilog-build.log" 2>&1
  vvp "$stem/test.vvp" "${args[@]}" | tee "$stem/iverilog-run.log"
  verilator --binary --build-jobs 2 --timing --assert --top-module "$top" --Mdir "$stem/obj" -Irtl -Isim/unit "${defines[@]}" -o directed "${rtl_sources[@]}" "sim/unit/$top.sv" > "$stem/verilator-build.log" 2>&1
  "$stem/obj/directed" "${args[@]}" | tee "$stem/verilator-run.log"
  grep ' PASS:' "$stem/iverilog-run.log" > "$stem/iverilog-result.txt"
  grep ' PASS:' "$stem/verilator-run.log" > "$stem/verilator-result.txt"
  cmp "$stem/iverilog-result.txt" "$stem/verilator-result.txt"
 done
done
sha256sum --check "$output/sources.sha256" > "$output/sources-verified.log"
echo GPR_PRIORITY_MUX_DIRECTED_PASS
