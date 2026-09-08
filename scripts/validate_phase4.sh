#!/usr/bin/env bash
# Full Phase 4 release gate, retaining every reviewed Phase 3 requirement.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export SPK286_BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build/phase4-final}"
mkdir -p "$SPK286_BUILD_DIR"
CORPUS="${SPK286_SINGLESTEP_ROOT:-$ROOT_DIR/.cache/singlestep-80286}"
test "$(git -C "$CORPUS" rev-parse HEAD)" = 37c73caf53dcd22d3dd369ff09305d13d117a4fe
test -z "$(git -C "$CORPUS" status --porcelain)"
python3 - "$CORPUS" <<'PY'
import sys
from pathlib import Path
from tools.run_singlestep import SUPPORTED_OPCODES
for opcode in SUPPORTED_OPCODES:
    path = Path(sys.argv[1]) / 'v1_real_mode' / (opcode+'.MOO.gz')
    if not path.is_file():
        raise SystemExit(f'Missing mandatory release corpus: {path}')
PY
# Includes double regeneration and hashes, all Python/compiler/audit tests,
# lint, all dual-simulator benches, inherited full hardware families, synthesis,
# regression, parser/comparator and Phase 3 boundary mutations, traced replays,
# failure propagation and generated-file Git cleanliness. No inherited skip.
make phase3-check
make singlestep-alu-smoke singlestep-alu
mkdir -p "$SPK286_BUILD_DIR/singlestep/phase4-full-reports"
python3 - "$SPK286_BUILD_DIR/singlestep" <<'PY'
import shutil
import sys
from pathlib import Path
from tools.run_singlestep import ALU_OPCODES
root = Path(sys.argv[1])
for opcode in ALU_OPCODES:
    shutil.copy2(root / 'reports' / (opcode+'.json'), root / 'phase4-full-reports')
PY
make alu-audit
make microcode-check
git diff --exit-code -- microcode/generated
echo "PHASE4_VALIDATION_PASS"
