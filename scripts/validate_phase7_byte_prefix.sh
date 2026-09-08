#!/usr/bin/env bash
# A bounded development increment. This is not the complete Phase 7 gate.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build/phase7-byte-prefix-final}"
if [[ -e "$BUILD_DIR" ]]; then
    echo "PHASE7_BYTE_PREFIX_VALIDATION_FAIL: choose a previously absent build directory" >&2
    exit 1
fi
mkdir -p "$BUILD_DIR"
stage=inputs
trap 'status=$?; echo "PHASE7_BYTE_PREFIX_VALIDATION_FAIL: stage=$stage status=$status" >&2; exit "$status"' ERR
python3 -m tools.phase6_inputs --manifest "$BUILD_DIR/inputs.json"
sha256sum docs/phase7_forms.json > "$BUILD_DIR/forms.sha256"
stage=inherited-executable
SPK286_BUILD_DIR="$BUILD_DIR/phase6" make phase6-exec-check
stage=all-supported-prefix-hardware
python3 - "$BUILD_DIR" <<'PYRUN'
from pathlib import Path
import subprocess
import sys
from tools.phase7_reports import COHORT
root=Path(sys.argv[1])
command=[sys.executable,'-m','tools.run_singlestep','--build-dir',str(root),'--executable',str(root/'phase6/verilator/obj_dir/spk286_smoke'),'--full','--include-exceptions','--include-prefixes']
for opcode in COHORT:command.extend(('--opcode',opcode))
subprocess.run(command,check=True)
PYRUN
python3 -m tools.phase7_reports --directory "$BUILD_DIR/singlestep" --output "$BUILD_DIR/byte-prefix-summary.json"
stage=prefix-parser-comparator-audit
python3 -m tools.audit_singlestep --build-dir "$BUILD_DIR/phase6" --include-prefixes
stage=byte-prefix-mutations
python3 -m tools.audit_byte_prefix --build-dir "$BUILD_DIR"
stage=consistency
python3 -m tools.phase6_inputs --manifest "$BUILD_DIR/inputs.json" --check
sha256sum --check "$BUILD_DIR/forms.sha256"
python3 -m tools.phase6_development --ci-status
echo "PHASE7_BYTE_PREFIX_VALIDATION_PASS: bounded increment; complete Phase 7 remains pending"
