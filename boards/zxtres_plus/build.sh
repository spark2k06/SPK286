#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the SPK286 bring-up demo for the ZXTRES+ with AMD Vivado and convert
# the bitstream to a .ZX3 core.
#
#   boards/zxtres_plus/build.sh [CPU_MHZ]
#
# CPU_MHZ is 40 (default) or 50. Needs python3, nasm (on PATH or in WSL) and
# Vivado (VIVADO, else vivado on PATH, else D:\AMD\2025.2). Output goes to
# build/zxtres_plus/<CPU_MHZ>mhz/: SPK286DEMO.ZX3, zxtres_demo.bit, demo.lst
# and the timing and utilization reports.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
CPU_MHZ="${1:-40}"
case "$CPU_MHZ" in
    40) CPU_DIVIDE=25 ;;
    50) CPU_DIVIDE=20 ;;
    *) echo "CPU_MHZ must be 40 or 50" >&2; exit 2 ;;
esac
PART=xc7a100tfgg484-2
OUT="$ROOT_DIR/build/zxtres_plus/${CPU_MHZ}mhz"
REL="build/zxtres_plus/${CPU_MHZ}mhz"

if [[ -z "${VIVADO:-}" ]]; then
    for candidate in "$(command -v vivado 2>/dev/null || true)" \
                     /d/AMD/2025.2/Vivado/bin/vivado.bat \
                     /mnt/d/AMD/2025.2/Vivado/bin/vivado.bat; do
        [[ -n "$candidate" && -e "$candidate" ]] && { VIVADO="$candidate"; break; }
    done
fi
[[ -n "${VIVADO:-}" ]] || { echo "vivado not found; set VIVADO" >&2; exit 1; }

# NASM, or the one in WSL when running from Windows (Git Bash) without it.
# Paths are relative to the repository root, which both sides share.
assemble() {
    if command -v nasm >/dev/null 2>&1; then nasm "$@"
    elif command -v wsl.exe >/dev/null 2>&1; then MSYS_NO_PATHCONV=1 wsl.exe nasm "$@"
    else echo "nasm not found" >&2; return 1
    fi
}

# A fresh run directory: never reuse an older Vivado run.
rm -rf "${OUT:?}"
mkdir -p "$OUT"
cd "$ROOT_DIR"
assemble -f bin -l "$REL/demo.lst" -o "$REL/demo.bin" boards/zxtres_plus/demo.asm
python3 "$HERE/make_mem.py" rom "$OUT/demo.bin" "$OUT/demo_rom.mem"
python3 "$HERE/make_mem.py" text "$OUT/demo_text.mem"
python3 "$HERE/make_mem.py" font "$HERE/font8x8.hex" "$OUT/font8x8.mem"

source scripts/rtl_sources.sh
sources=("${rtl_sources[@]}"
         boards/zxtres_plus/zxtres_cdc_snapshot.sv
         boards/zxtres_plus/zxtres_text_vga.sv
         boards/zxtres_plus/zxtres_demo_system.sv
         boards/zxtres_plus/zxtres_demo_top.sv)
# Freeze the inputs: later edits to the tree cannot leak into this run.
for source in "${sources[@]}"; do
    mkdir -p "$OUT/src/$(dirname "$source")"
    cp "$source" "$OUT/src/$source"
    echo "src/$source"
done > "$OUT/sources.txt"
cp "$HERE/zxtres_demo.xdc" "$HERE/build.tcl" "$OUT/"
git rev-parse HEAD > "$OUT/source-revision.txt"
git status --short > "$OUT/source-status.txt"

cd "$OUT"
"$VIVADO" -mode batch -log vivado.log -journal vivado.jou -source build.tcl \
    -tclargs "$PART" "$CPU_DIVIDE" > console.log 2>&1 \
    || { grep -E '^(ERROR|CRITICAL WARNING)' vivado.log | head -20 >&2; exit 1; }

python3 "$HERE/bit_to_zx3.py" zxtres_demo.bit SPK286DEMO.ZX3
cat result.txt
grep -E '^\| (Slice LUTs|Slice Registers|Block RAM Tile|DSPs)' utilization.rpt | head -4
echo "critical warnings: $(grep -c '^CRITICAL WARNING' vivado.log || true)"
