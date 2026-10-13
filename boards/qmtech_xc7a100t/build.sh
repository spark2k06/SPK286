#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build SPK286 with spk286_native for the QMTECH XC7A100T core board using
# the open-source openXC7 flow: Yosys -> nextpnr-xilinx -> prjxray bitstream.
#
#   boards/qmtech_xc7a100t/build.sh [CLK_MHZ] [SEED]
#
# CLK_MHZ is the bus CLK constraint (twice the 80286 processor clock,
# default 32). Output goes to build/qmtech_xc7a100t/<CLK_MHZ>mhz_seed<SEED>/.
# Tools are taken from OSS_CAD_SUITE (YosysHQ oss-cad-suite, for yosys) and
# OPENXC7 (openXC7 toolchain package with nextpnr-xilinx, the chip databases
# and the prjxray bitstream tools); see README.md in this directory.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/opt/oss-cad-suite}"
OPENXC7="${OPENXC7:-$HOME/opt/openxc7}"
YOSYS="${YOSYS:-$OSS_CAD_SUITE/bin/yosys}"
PART="${PART:-xc7a100tfgg676-1}"
DB="$OPENXC7/share/nextpnr/external/prjxray-db/artix7"
CLK_MHZ="${1:-32}"
SEED="${2:-1}"
OUT="$ROOT_DIR/build/qmtech_xc7a100t/${CLK_MHZ}mhz_seed${SEED}"

for tool in "$YOSYS" "$OPENXC7/bin/nextpnr-xilinx" "$OPENXC7/bin/fasm2frames" "$OPENXC7/bin/xc7frames2bit"; do
    [[ -x "$tool" ]] || { echo "missing $tool; see boards/qmtech_xc7a100t/README.md" >&2; exit 1; }
done
mkdir -p "$OUT"
python3 "$HERE/gen_xdc.py" "$OUT/spk286_qmtech.xdc" "$CLK_MHZ"

cd "$ROOT_DIR"
source scripts/rtl_sources.sh
sources=("${rtl_sources[@]}" rtl/native/spk286_native.sv boards/qmtech_xc7a100t/spk286_qmtech_top.sv)

"$YOSYS" -q -l "$OUT/yosys.log" -p "read_verilog -sv ${sources[*]};
    synth_xilinx -flatten -abc9 -arch xc7 -top spk286_qmtech_top;
    tee -q -o $OUT/yosys_stat.txt stat; write_json $OUT/top.json"

"$OPENXC7/bin/nextpnr-xilinx" --device "$PART" --json "$OUT/top.json" \
    -o xdc="$OUT/spk286_qmtech.xdc" -o fasm="$OUT/top.fasm" \
    --report "$OUT/report.json" --seed "$SEED" --threads "${THREADS:-8}" --timing-allow-fail \
    > "$OUT/nextpnr.log" 2>&1 || { tail -20 "$OUT/nextpnr.log" >&2; exit 1; }

"$OPENXC7/bin/fasm2frames" --part "$PART" --db-root "$DB" "$OUT/top.fasm" > "$OUT/top.frames"
"$OPENXC7/bin/xc7frames2bit" --part_file "$DB/$PART/part.yaml" --part_name "$PART" \
    --frm_file "$OUT/top.frames" --output_file "$OUT/spk286_qmtech.bit"

python3 "$HERE/summary.py" "$OUT"
