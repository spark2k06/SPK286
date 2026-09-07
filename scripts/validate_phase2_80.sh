#!/usr/bin/env bash
# Complete phase gate; no optional external-data skips are accepted here.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build/phase2.80}"
export SPK286_BUILD_DIR="$BUILD_DIR"
mkdir -p "$BUILD_DIR"
CORPUS="${SPK286_SINGLESTEP_ROOT:-$ROOT_DIR/.cache/singlestep-80286}"
test "$(git -C "$CORPUS" rev-parse HEAD)" = 37c73caf53dcd22d3dd369ff09305d13d117a4fe
test -z "$(git -C "$CORPUS" status --porcelain)"
for opcode in B8 B9 BA BB BC BD BE BF; do
    test -f "$CORPUS/v1_real_mode/$opcode.MOO.gz"
done
make mcl86-test mcl86-check microcode microcode-check microcode-test microcode-audit
python3 -m unittest discover -s tests -p 'test_*.py' -v
make lint
bash scripts/test_units.sh both
make waveform iverilog state-smoke
make singlestep-smoke
python3 -m tools.run_singlestep --sample 100
make singlestep-mov
make synth-check
make regression
make verify-failure data-smoke
python3 -m tools.run_singlestep --opcode B8 --index 0 --trace "$BUILD_DIR/traces/microcode-B8-0.vcd"
python3 -m tools.microcode.compile_microcode --pc 0x1
make microcode-check
git diff --exit-code -- microcode/generated
echo "PHASE2_80_VALIDATION_PASS"
