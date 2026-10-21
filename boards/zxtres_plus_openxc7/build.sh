#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the ZXTRES+ bring-up demo (boards/zxtres_plus) with the open-source
# openXC7 flow: Yosys -> nextpnr-xilinx -> prjxray bitstream -> .ZX3 core.
#
#   boards/zxtres_plus_openxc7/build.sh [CPU_MHZ] [SEED]
#
# CPU_MHZ is 33 (default, 33.333 MHz), 31 (31.25 MHz) or 40. Run from Linux
# or WSL. Tools are taken from OSS_CAD_SUITE (yosys) and OPENXC7 (nextpnr-
# xilinx, the chip databases, fasm2frames, xc7frames2bit); nasm and python3
# come from PATH. Output goes to build/zxtres_plus_openxc7/<CPU_MHZ>mhz_seed<SEED>/:
# SPK286DEMO.ZX3, zxtres_demo.bit, demo.lst, the logs and summary.txt. The
# bitstream is not compressed: the core is 3.8 MB and the ZXTRES+ loads it as
# is. COMPRESS=1 compresses it as Vivado does, but a core built that way did
# not start on the board (see README.md), so it stays off. The build fails
# when a clock misses its constraint, when the bitstream, read back, does not
# hold exactly the design nextpnr placed and routed, or when the final
# bitstream writes different frames.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
DEMO="$ROOT_DIR/boards/zxtres_plus"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/opt/oss-cad-suite}"
OPENXC7="${OPENXC7:-$HOME/opt/openxc7}"
YOSYS="${YOSYS:-$OSS_CAD_SUITE/bin/yosys}"
PART=xc7a100tfgg484-2
DB="$OPENXC7/share/nextpnr/external/prjxray-db/artix7"
CPU_MHZ="${1:-33}"
SEED="${2:-1}"
case "$CPU_MHZ" in
    40) CPU_DIVIDE=25; CPU_FREQ=40 ;;
    33) CPU_DIVIDE=30; CPU_FREQ=33.333 ;;
    31) CPU_DIVIDE=32; CPU_FREQ=31.25 ;;
    *) echo "CPU_MHZ must be 40, 33 or 31" >&2; exit 2 ;;
esac
OUT="$ROOT_DIR/build/zxtres_plus_openxc7/${CPU_MHZ}mhz_seed${SEED}"

for tool in "$YOSYS" "$OPENXC7/bin/nextpnr-xilinx" "$OPENXC7/bin/fasm2frames" \
            "$OPENXC7/bin/xc7frames2bit"; do
    [[ -x "$tool" ]] || { echo "missing $tool; see boards/zxtres_plus_openxc7/README.md" >&2; exit 1; }
done
command -v nasm >/dev/null || { echo "nasm not found" >&2; exit 1; }

# A fresh run directory: never reuse an older run.
rm -rf "${OUT:?}"
mkdir -p "$OUT"
cd "$ROOT_DIR"
nasm -f bin -l "$OUT/demo.lst" -o "$OUT/demo.bin" "$DEMO/demo.asm"
python3 "$DEMO/make_mem.py" rom "$OUT/demo.bin" "$OUT/demo_rom.mem"
python3 "$DEMO/make_mem.py" text "$OUT/demo_text.mem"
python3 "$DEMO/make_mem.py" font "$DEMO/font8x8.hex" "$OUT/font8x8.mem"
python3 "$HERE/gen_xdc.py" "$DEMO/zxtres_demo.xdc" "$OUT/zxtres_demo.xdc" "$CPU_FREQ"

source scripts/rtl_sources.sh
sources=("${rtl_sources[@]}"
         boards/zxtres_plus/zxtres_cdc_snapshot.sv
         boards/zxtres_plus/zxtres_text_vga.sv
         boards/zxtres_plus/zxtres_demo_system.sv
         boards/zxtres_plus_openxc7/zxtres_demo_top_openxc7.sv)
git rev-parse HEAD > "$OUT/source-revision.txt"
git status --short > "$OUT/source-status.txt"

# Yosys runs in the output directory, where $readmemh finds the images.
cd "$OUT"
"$YOSYS" -q -l yosys.log -p "read_verilog -sv ${sources[*]/#/$ROOT_DIR/};
    chparam -set CPU_DIVIDE $CPU_DIVIDE zxtres_demo_top_openxc7;
    synth_xilinx -flatten -abc9 -arch xc7 -top zxtres_demo_top_openxc7;
    tee -q -o yosys_stat.txt stat; write_json top.json"

"$OPENXC7/bin/nextpnr-xilinx" --device "$PART" --json top.json \
    -o xdc=zxtres_demo.xdc -o fasm=top.fasm --report report.json \
    --seed "$SEED" --threads "${THREADS:-8}" --timing-allow-fail \
    > nextpnr.log 2>&1 || { tail -20 nextpnr.log >&2; exit 1; }

"$OPENXC7/bin/fasm2frames" --part "$PART" --db-root "$DB" top.fasm > top.frames
"$OPENXC7/bin/xc7frames2bit" --part_file "$DB/$PART/part.yaml" --part_name "$PART" \
    --frm_file top.frames --output_file prjxray.bit

# Read the prjxray bitstream back and compare it with what nextpnr placed.
"$OPENXC7/bin/bitread" --part_file "$DB/$PART/part.yaml" -o readback.bits -z -y prjxray.bit \
    > bitread.log 2>&1
"$OPENXC7/libexec/tabbypy3" "$HERE/check_readback.py" "$DB" "$PART" readback.bits top.fasm \
    | tee readback.txt
rm -f readback.bits

# Optionally compress it as Vivado does (bitread cannot follow that, so
# decode_frames.py checks it), then add the ZXTRES+ flash read settings Vivado
# writes (SPI x4, 4-byte addresses). The final bitstream must write the same
# frames.
if [[ "${COMPRESS:-0}" == 1 ]]; then
    python3 "$HERE/compress_bitstream.py" "$DB/$PART/part.yaml" top.frames prjxray.bit compressed.bit
else
    cp prjxray.bit compressed.bit
fi
python3 "$HERE/zxtres_bitstream.py" compressed.bit zxtres_demo.bit
python3 "$HERE/decode_frames.py" "$DB/$PART/part.yaml" prjxray.bit zxtres_demo.bit | tee frames.txt
python3 "$HERE/bit_packets.py" zxtres_demo.bit > bit_packets.txt

python3 "$DEMO/bit_to_zx3.py" zxtres_demo.bit SPK286DEMO.ZX3
python3 "$HERE/summary.py" . | tee summary.txt
