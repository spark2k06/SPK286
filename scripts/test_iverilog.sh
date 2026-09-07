#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build}"
OUTPUT="$BUILD_DIR/iverilog/spk286_reset_tb.vvp"
mkdir -p "$(dirname "$OUTPUT")"
cd "$ROOT_DIR"
source scripts/rtl_sources.sh

command -v iverilog >/dev/null 2>&1 || {
    echo "iverilog is required; run ./scripts/bootstrap.sh" >&2
    exit 1
}
command -v vvp >/dev/null 2>&1 || {
    echo "vvp is required; run ./scripts/bootstrap.sh" >&2
    exit 1
}

iverilog -g2012 -Wall -Isim/unit -s spk286_reset_tb -o "$OUTPUT" \
    "${rtl_sources[@]}" sim/iverilog/spk286_reset_tb.sv
vvp "$OUTPUT"
