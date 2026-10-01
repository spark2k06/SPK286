#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output=$(realpath -m "${1:-$root/build/decoder-support}")
[[ $# -le 1 && ! -e "$output" ]]
cd "$root"
mkdir -p "$output"
python3 scripts/prove_decoder_support.py "$output/formal" | tee "$output/formal-result.log"
source scripts/rtl_sources.sh
for profile in base pcat; do
  defines=()
  if [[ $profile == pcat ]]; then
    defines=(-DSPK286_P01_FAST_MEMORY_START -DSPK286_P02_FETCH_CHAIN
             -DSPK286_P05_PARALLEL_LIMIT_CHECK -DSPK286_P06_EARLY_MEMORY_ADDRESS)
  fi
  verilator --lint-only --language 1800-2012 --Wall --top-module spk286 \
    -Irtl "${defines[@]}" "${rtl_sources[@]}" > "$output/$profile-lint.log" 2>&1
done
top=spk286_decoder_support_equivalence_tb
sources=(microcode/generated/spk286_microcode_pkg.sv rtl/spk286_decoder.sv
         "$output/formal/reference.sv" sim/unit/$top.sv)
iverilog -g2012 -s "$top" -o "$output/test.vvp" "${sources[@]}" > "$output/iverilog-build.log" 2>&1
vvp "$output/test.vvp" | tee "$output/iverilog-run.log"
verilator --binary --timing --assert --build-jobs 2 --top-module "$top" \
  --Mdir "$output/verilator" -o directed "${sources[@]}" > "$output/verilator-build.log" 2>&1
"$output/verilator/directed" | tee "$output/verilator-run.log"
grep ' PASS:' "$output/iverilog-run.log" > "$output/iverilog-result.txt"
grep ' PASS:' "$output/verilator-run.log" > "$output/verilator-result.txt"
cmp "$output/iverilog-result.txt" "$output/verilator-result.txt"
sha256sum rtl/spk286_decoder.sv scripts/prove_decoder_support.py scripts/test_decoder_support.sh \
  sim/unit/$top.sv > "$output/sources.sha256"
echo DECODER_SUPPORT_DIRECTED_PASS
