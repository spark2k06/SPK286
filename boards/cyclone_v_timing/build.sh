#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# CPU-only timing build for the DE10-Nano's Cyclone V (5CSEBA6U23I7) with
# Quartus Prime Lite 17.0 from the raetro/quartus:mister container. The top
# is spk286_native, which ties the core's setup and debug ports as a system
# integration does; every pin except clk is virtual, so only register paths
# are timed, against a 50 MHz clock (the MiSTer PC/AT CPU clock).
#
#   boards/cyclone_v_timing/build.sh [SEED] [TAG]
#
# Output goes to build/cyclone_v_timing/<TAG>_seed<SEED>/ (TAG defaults to
# "run"); summary.txt holds the slack, fmax, resources and the worst paths
# grouped by module.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
IMAGE="${QUARTUS_IMAGE:-raetro/quartus:mister}"
SEED="${1:-1}"
TAG="${2:-run}"
OUT="$ROOT_DIR/build/cyclone_v_timing/${TAG}_seed$SEED"

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
# A fresh project directory: never reuse an older Quartus database.
rm -rf "${OUT:?}"
mkdir -p "$OUT"

cd "$ROOT_DIR"
source scripts/rtl_sources.sh
sources=("${rtl_sources[@]}" rtl/native/spk286_native.sv)
# Freeze the inputs: later edits to the tree cannot leak into this run.
for source in "${sources[@]}"; do
    mkdir -p "$OUT/src/$(dirname "$source")"
    cp "$source" "$OUT/src/$source"
done
{
    echo 'set_global_assignment -name FAMILY "Cyclone V"'
    echo 'set_global_assignment -name DEVICE 5CSEBA6U23I7'
    echo 'set_global_assignment -name TOP_LEVEL_ENTITY spk286_native'
    echo "set_global_assignment -name SEED $SEED"
    echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 4'
    echo 'set_global_assignment -name SDC_FILE spk286_timing.sdc'
    for source in "${sources[@]}"; do
        echo "set_global_assignment -name SYSTEMVERILOG_FILE src/$source"
    done
    echo 'set_instance_assignment -name VIRTUAL_PIN ON -to *'
    echo 'set_instance_assignment -name VIRTUAL_PIN OFF -to clk'
} > "$OUT/spk286_timing.qsf"
echo 'PROJECT_REVISION = "spk286_timing"' > "$OUT/spk286_timing.qpf"
cp "$HERE/spk286_timing.sdc" "$HERE/report.tcl" "$OUT/"

docker run --rm -v "$OUT:/build" -w /build "$IMAGE" \
    quartus_sh --flow compile spk286_timing > "$OUT/compile.log" 2>&1 \
    || { grep -E '^Error' "$OUT/compile.log" | head -20 >&2; exit 1; }
docker run --rm -v "$OUT:/build" -w /build "$IMAGE" \
    quartus_sta -t report.tcl > "$OUT/report.log" 2>&1 \
    || { tail -20 "$OUT/report.log" >&2; exit 1; }

python3 "$HERE/summary.py" "$OUT" | tee "$OUT/summary.txt"
