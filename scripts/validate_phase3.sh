#!/usr/bin/env bash
# Mandatory release gate. Optional corpus skips in daily regression are insufficient.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build/phase3-final}"
export SPK286_BUILD_DIR="$BUILD_DIR"
mkdir -p "$BUILD_DIR"
CORPUS="${SPK286_SINGLESTEP_ROOT:-$ROOT_DIR/.cache/singlestep-80286}"
test "$(git -C "$CORPUS" rev-parse HEAD)" = 37c73caf53dcd22d3dd369ff09305d13d117a4fe
test -z "$(git -C "$CORPUS" status --porcelain)"
for opcode in B8 B9 BA BB BC BD BE BF 89 8B; do
    test -f "$CORPUS/v1_real_mode/$opcode.MOO.gz"
done
make microcode
sha256sum microcode/generated/* > "$BUILD_DIR/generated.sha256"
make microcode
sha256sum -c "$BUILD_DIR/generated.sha256"
make microcode-check microcode-test microcode-audit
make mcl86-check
python3 -m unittest discover -s tests -p 'test_*.py' -v
make lint
bash scripts/test_units.sh both
make waveform iverilog state-smoke
make singlestep-smoke
make singlestep-operands singlestep-mov
# Preserve full-run summaries before daily smoke overwrites per-opcode reports.
mkdir -p "$BUILD_DIR/singlestep/full-reports"
cp "$BUILD_DIR/singlestep/reports/"*.json "$BUILD_DIR/singlestep/full-reports/"
make synth-check
make regression
make singlestep-audit
make phase3-boundary-audit
make verify-failure data-smoke
python3 -m tools.run_singlestep --opcode 89 --index 0 --trace "$BUILD_DIR/traces/mov-89-0.vcd"
python3 -m tools.run_singlestep --opcode 8B --index 3 --trace "$BUILD_DIR/traces/mov-8B-3.vcd"
make microcode-check
git diff --exit-code -- microcode/generated
echo "PHASE3_VALIDATION_PASS"
