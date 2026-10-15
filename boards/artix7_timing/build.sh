#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# CPU-only timing build for Xilinx 7-series parts with AMD Vivado (batch
# mode). The top is spk286_native, synthesized out of context: its ports get
# no I/O buffers and clk is assumed to come from a global buffer, so only the
# core's register-to-register paths are timed (the counterpart of the virtual
# pins in boards/cyclone_v_timing).
#
#   boards/artix7_timing/build.sh [PART] [CLK_MHZ] [TAG]
#
# PART defaults to xc7a100tfgg484-2 (ZXTRES+), CLK_MHZ to 50. Output goes to
# build/artix7_timing/<TAG>_<PART>_<CLK_MHZ>mhz/ (TAG defaults to "run");
# summary.txt holds the slack, fmax, logic levels, resources and the worst
# paths grouped by module. VIVADO names the vivado executable (vivado.bat on
# Windows); it defaults to vivado on PATH, then to D:\AMD\2025.2.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
PART="${1:-xc7a100tfgg484-2}"
CLK_MHZ="${2:-50}"
TAG="${3:-run}"
OUT="$ROOT_DIR/build/artix7_timing/${TAG}_${PART}_${CLK_MHZ}mhz"

if [[ -z "${VIVADO:-}" ]]; then
    for candidate in "$(command -v vivado 2>/dev/null || true)" \
                     /d/AMD/2025.2/Vivado/bin/vivado.bat \
                     /mnt/d/AMD/2025.2/Vivado/bin/vivado.bat; do
        [[ -n "$candidate" && -e "$candidate" ]] && { VIVADO="$candidate"; break; }
    done
fi
[[ -n "${VIVADO:-}" ]] || { echo "vivado not found; set VIVADO" >&2; exit 1; }

# A fresh project directory: never reuse an older Vivado run.
rm -rf "${OUT:?}"
mkdir -p "$OUT"

cd "$ROOT_DIR"
source scripts/rtl_sources.sh
sources=("${rtl_sources[@]}" rtl/native/spk286_native.sv)
# Freeze the inputs: later edits to the tree cannot leak into this run.
for source in "${sources[@]}"; do
    mkdir -p "$OUT/src/$(dirname "$source")"
    cp "$source" "$OUT/src/$source"
    echo "src/$source"
done > "$OUT/sources.txt"
cp "$HERE/build.tcl" "$OUT/"
period=$(python3 -c "print(f'{1000 / float($CLK_MHZ):.3f}')")

cd "$OUT"
"$VIVADO" -mode batch -log vivado.log -journal vivado.jou -source build.tcl \
    -tclargs "$PART" "$period" > console.log 2>&1 \
    || { grep -E '^(ERROR|CRITICAL WARNING)' vivado.log | head -20 >&2; exit 1; }

python3 "$HERE/summary.py" "$OUT" | tee "$OUT/summary.txt"
