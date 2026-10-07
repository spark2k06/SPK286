#!/usr/bin/env bash
# Cross-check the SingleStep parser and comparators against independent
# decoders and injected comparison faults.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build}"
CORPUS="${SPK286_SINGLESTEP_ROOT:-$ROOT_DIR/.cache/singlestep-80286}"
EXE="$BUILD_DIR/verilator/obj_dir/spk286_smoke"
cd "$ROOT_DIR"

python3 -m tools.audit_singlestep --repo "$CORPUS" --build-dir "$BUILD_DIR" --include-prefixes
python3 -m tools.audit_scalar_io --repo "$CORPUS" --build-dir "$BUILD_DIR"
rm -rf "$BUILD_DIR/audit-muldiv-adapter" "$BUILD_DIR/audit-combined-adapter"
python3 -m tools.audit_muldiv_adapter --repo "$CORPUS" --executable "$EXE" --build-dir "$BUILD_DIR/audit-muldiv-adapter"
python3 -m tools.audit_combined_adapter --repo "$CORPUS" --executable "$EXE" --build-dir "$BUILD_DIR/audit-combined-adapter"
echo "SINGLESTEP AUDIT PASS"
