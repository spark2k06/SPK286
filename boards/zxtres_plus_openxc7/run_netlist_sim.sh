#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Simulate the demo system as Yosys synthesizes it for the openXC7 flow, and
# compare it with the RTL simulation. Run from Linux or WSL:
#
#   boards/zxtres_plus_openxc7/run_netlist_sim.sh [MAX_MS]
#
# Yosys (synth_xilinx, the options of build.sh) turns zxtres_demo_system
# into LUTs, carry chains, flip-flops and block RAM with the ROM and font
# baked in; Verilator runs that netlist with Yosys's Xilinx cell models (the
# block RAMs from xc7_bram_sim.sv, since Yosys's have no behaviour) and the
# demo testbench (ZXTRES_NETLIST). boards/zxtres_plus/run_sim.sh runs the
# RTL. The POST code sequence and both captured VGA frames must be identical.
# Output in build/zxtres_plus_openxc7/netlist-sim.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/../.." && pwd)"
DEMO="$ROOT_DIR/boards/zxtres_plus"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/opt/oss-cad-suite}"
YOSYS="${YOSYS:-$OSS_CAD_SUITE/bin/yosys}"
CELLS="$OSS_CAD_SUITE/share/yosys/xilinx/cells_sim.v"
OUT="$ROOT_DIR/build/zxtres_plus_openxc7/netlist-sim"
RTL="$ROOT_DIR/build/zxtres_plus/sim"
MAX_MS="${1:-400}"

[[ -x "$YOSYS" && -f "$CELLS" ]] || { echo "yosys or $CELLS missing" >&2; exit 1; }
rm -rf "${OUT:?}"
mkdir -p "$OUT"

bash "$DEMO/run_sim.sh" "$MAX_MS" > "$OUT/rtl.log"

cd "$ROOT_DIR"
nasm -f bin -o "$OUT/demo.bin" "$DEMO/demo.asm"
python3 "$DEMO/make_mem.py" rom "$OUT/demo.bin" "$OUT/demo_rom.mem"
python3 "$DEMO/make_mem.py" text "$OUT/demo_text.mem"
python3 "$DEMO/make_mem.py" font "$DEMO/font8x8.hex" "$OUT/font8x8.mem"
source scripts/rtl_sources.sh
sources=("${rtl_sources[@]}"
         boards/zxtres_plus/zxtres_cdc_snapshot.sv
         boards/zxtres_plus/zxtres_text_vga.sv
         boards/zxtres_plus/zxtres_demo_system.sv)

cd "$OUT"
"$YOSYS" -q -l yosys.log -p "read_verilog -sv ${sources[*]/#/$ROOT_DIR/};
    synth_xilinx -flatten -abc9 -arch xc7 -top zxtres_demo_system;
    tee -q -o yosys_stat.txt stat; write_verilog -noattr netlist.v"

# Yosys's RAMB18E1/RAMB36E1 have no behaviour; xc7_bram_sim.sv replaces them.
python3 "$HERE/strip_cells.py" "$CELLS" cells_sim.v RAMB18E1 RAMB36E1
verilator --binary --timing -O2 --build-jobs 4 -Wno-fatal -Wno-lint -Wno-style \
    +define+ZXTRES_NETLIST --top-module zxtres_demo_tb --Mdir obj -o netlist_sim \
    cells_sim.v "$HERE/xc7_bram_sim.sv" netlist.v "$DEMO/zxtres_demo_tb.sv" \
    > verilator-build.log 2>&1 \
    || { grep -E '%Error' verilator-build.log | head -20 >&2; exit 1; }
./obj/netlist_sim +OUT=netlist +MAX_MS="$MAX_MS" | tee sim.log

# The same POST codes at the same times, and the same frames.
grep -E '\] POST |stop condition|VGA sync errors' "$RTL/sim.log" > rtl_events.txt
grep -E '\] POST |stop condition|VGA sync errors' sim.log > netlist_events.txt
status=0
if cmp -s rtl_events.txt netlist_events.txt; then
    echo "POST sequence: identical ($(grep -c POST netlist_events.txt) codes)"
else
    echo "POST sequence: DIFFERENT"; diff rtl_events.txt netlist_events.txt | head -10; status=1
fi
for frame in 0 1; do
    if cmp -s "$RTL/zxtres_demo_frame$frame.ppm" "netlist_frame$frame.ppm"; then
        echo "frame $frame: identical"
    else
        echo "frame $frame: DIFFERENT"; status=1
    fi
    python3 "$DEMO/ppm_to_png.py" "netlist_frame$frame.ppm" "netlist_frame$frame.png"
done
echo "$([[ $status == 0 ]] && echo NETLIST PASS || echo NETLIST FAIL)"
exit $status
