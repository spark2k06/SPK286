#!/usr/bin/env bash
# A integer-arithmetic development increment; required remaining Phase 7 forms stay pending.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build/phase7-arithmetic-final}"
if [[ -e "$BUILD_DIR" ]]; then
    echo "PHASE7_ARITHMETIC_VALIDATION_FAIL: choose a previously absent build directory" >&2
    exit 1
fi
mkdir -p "$BUILD_DIR"
stage=inputs
trap 'status=$?; echo "PHASE7_ARITHMETIC_VALIDATION_FAIL: stage=$stage status=$status" >&2; exit "$status"' ERR
python3 -m tools.phase6_inputs --manifest "$BUILD_DIR/inputs.json"
sha256sum docs/phase7_forms.json > "$BUILD_DIR/forms.sha256"
stage=far-and-inherited-executable
SPK286_BUILD_DIR="$BUILD_DIR/far" make phase7-far-check
stage=all-arithmetic-physical
python3 - "$BUILD_DIR" <<'PYRUN'
from pathlib import Path
import subprocess
import sys
from tools.phase7_arithmetic_reports import COHORT
root=Path(sys.argv[1])
command=[sys.executable,'-m','tools.run_singlestep','--build-dir',str(root),'--executable',str(root/'far/stack-frame/segment/adjust/unary/data/shift/scalar/byte/phase6/verilator/obj_dir/spk286_smoke'),'--full','--include-exceptions','--include-prefixes']
for opcode in COHORT:command.extend(('--opcode',opcode))
subprocess.run(command,check=True)
PYRUN
python3 -m tools.phase7_arithmetic_reports --directory "$BUILD_DIR/singlestep" --far-directory "$BUILD_DIR/far/singlestep" --stack-frame-directory "$BUILD_DIR/far/stack-frame/singlestep" --segment-directory "$BUILD_DIR/far/stack-frame/segment/singlestep" --adjust-directory "$BUILD_DIR/far/stack-frame/segment/adjust/singlestep" --unary-directory "$BUILD_DIR/far/stack-frame/segment/adjust/unary/singlestep" --data-directory "$BUILD_DIR/far/stack-frame/segment/adjust/unary/data/singlestep" --shift-directory "$BUILD_DIR/far/stack-frame/segment/adjust/unary/data/shift/singlestep" --scalar-directory "$BUILD_DIR/far/stack-frame/segment/adjust/unary/data/shift/scalar/singlestep" --byte-directory "$BUILD_DIR/far/stack-frame/segment/adjust/unary/data/shift/scalar/byte/singlestep" --output "$BUILD_DIR/arithmetic-summary.json"
stage=arithmetic-mutations
python3 -m tools.audit_muldiv --build-dir "$BUILD_DIR"
stage=arithmetic-comparator
python3 -m tools.audit_muldiv_adapter --repo "${SPK286_SINGLESTEP_ROOT:-$ROOT_DIR/.cache/singlestep-80286}" --executable "$BUILD_DIR/far/stack-frame/segment/adjust/unary/data/shift/scalar/byte/phase6/verilator/obj_dir/spk286_smoke" --build-dir "$BUILD_DIR/arithmetic-comparator"
stage=consistency
python3 -m tools.phase6_inputs --manifest "$BUILD_DIR/inputs.json" --check
sha256sum --check "$BUILD_DIR/forms.sha256"
python3 -m tools.phase6_development --ci-status
echo "PHASE7_ARITHMETIC_VALIDATION_PASS: bounded increment; complete Phase 7 remains pending"
