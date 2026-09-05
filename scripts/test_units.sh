#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build}"
cd "$ROOT_DIR"

simulator="${1:-both}"
unit="${2:-all}"
case "$simulator" in verilator|iverilog|both) ;; *) echo "Unknown simulator: $simulator" >&2; exit 2;; esac
tests=(spk286_registers spk286_segments spk286_fetch spk286_core)
if [[ "$unit" != all ]]; then tests=("$unit"); fi

for name in "${tests[@]}"; do
    tb="${name}_tb"
    test -f "sim/unit/$tb.sv"
    if [[ "$simulator" != iverilog ]]; then
        obj="$BUILD_DIR/verilator/$tb"
        mkdir -p "$obj"
        verilator --binary --timing --assert --language 1800-2012 \
            --top-module "$tb" --Mdir "$obj" -Irtl -Isim/unit \
            -o "$tb" rtl/*.sv "sim/unit/$tb.sv" >"$obj/build.log" 2>&1 || {
                cat "$obj/build.log"; exit 1;
            }
        cat "$obj/build.log"
        "$obj/$tb"
    fi
    if [[ "$simulator" != verilator ]]; then
        obj="$BUILD_DIR/iverilog/$tb"
        mkdir -p "$obj"
        iverilog -g2012 -Wall -Irtl -Isim/unit -s "$tb" -o "$obj/$tb.vvp" rtl/*.sv "sim/unit/$tb.sv"
        vvp "$obj/$tb.vvp"
    fi
done
