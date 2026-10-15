#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Assemble the ZXTRES+ demo, simulate the demo system with Verilator and
# render the captured VGA frames. Run from Linux or WSL:
#
#   boards/zxtres_plus/run_sim.sh [MAX_MS]
#
# Output in build/zxtres_plus/sim: zxtres_demo_screen.txt, the frames as PNG
# and sim.log. MAX_MS (default 400) bounds the simulated time. The run fails
# unless the demo reports that all its checks passed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT_DIR/build/zxtres_plus/sim"
MAX_MS="${1:-400}"
rm -rf "${OUT:?}"
mkdir -p "$OUT"
cd "$ROOT_DIR"

nasm -f bin -l "$OUT/demo.lst" -o "$OUT/demo.bin" boards/zxtres_plus/demo.asm
python3 "$HERE/make_mem.py" rom "$OUT/demo.bin" "$OUT/demo_rom.mem"
python3 "$HERE/make_mem.py" text "$OUT/demo_text.mem"
python3 "$HERE/make_mem.py" font "$HERE/font8x8.hex" "$OUT/font8x8.mem"

source scripts/rtl_sources.sh
verilator --binary --timing -O2 --x-initial fast -Wno-fatal -Wno-lint -Wno-style \
    --top-module zxtres_demo_tb --Mdir "$OUT/obj" -o zxtres_demo_sim \
    "${rtl_sources[@]}" \
    boards/zxtres_plus/zxtres_cdc_snapshot.sv boards/zxtres_plus/zxtres_text_vga.sv \
    boards/zxtres_plus/zxtres_demo_system.sv boards/zxtres_plus/zxtres_demo_tb.sv \
    > "$OUT/verilator-build.log" 2>&1 \
    || { grep -E '%Error' "$OUT/verilator-build.log" | head -20 >&2; exit 1; }

(cd "$OUT" && ./obj/zxtres_demo_sim +OUT=zxtres_demo +MAX_MS="$MAX_MS") | tee "$OUT/sim.log"
for frame in "$OUT"/zxtres_demo_frame*.ppm; do
    [[ -e "$frame" ]] && python3 "$HERE/ppm_to_png.py" "$frame" "${frame%.ppm}.png"
done
echo "== screen"
cat "$OUT/zxtres_demo_screen.txt"
grep -q "All 22 checks passed" "$OUT/zxtres_demo_screen.txt"
