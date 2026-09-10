#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mode="${1:-complete}"
case "$mode" in complete|executable) ;; *) echo "Unknown Phase 7 gate mode" >&2; exit 2;; esac
# Finalization requires all retained results and exact unchanged input manifests.
if [[ -n "${SPK286_PHASE7_RECEIPT:-}" ]]; then
    test "$mode" = complete
    python3 -m tools.phase7_completion --receipt "$SPK286_PHASE7_RECEIPT"
    exit 0
fi
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build/phase7-complete}"
if [[ -e "$BUILD_DIR" ]]; then
    echo "PHASE7_DEVELOPMENT_VALIDATION_FAIL: choose a previously absent build directory" >&2
    exit 1
fi
mkdir -p "$BUILD_DIR/logs"
stage=inputs
trap 'status=$?; echo "PHASE7_DEVELOPMENT_VALIDATION_FAIL: stage=$stage status=$status" >&2; exit "$status"' ERR
python3 -m tools.phase7_scope
python3 -m tools.phase6_inputs --manifest "$BUILD_DIR/inputs.json"
python3 -m tools.phase7_policy --manifest "$BUILD_DIR/policy-inputs.json"
stage=inherited-executable
{
    SPK286_BUILD_DIR="$BUILD_DIR/phase6" make phase6-exec-check
    echo "PHASE7_STAGE_PASS $stage"
} 2>&1 | tee "$BUILD_DIR/logs/$stage.log"
EXE="$BUILD_DIR/phase6/verilator/obj_dir/spk286_smoke"
CORPUS="${SPK286_SINGLESTEP_ROOT:-$ROOT_DIR/.cache/singlestep-80286}"
stage=complete-physical
{
    python3 -m tools.run_phase7_physical --repo "$CORPUS" --executable "$EXE" --build-dir "$BUILD_DIR/physical"
    python3 -m tools.phase7_complete_reports --repo "$CORPUS" --directory "$BUILD_DIR/physical/singlestep" --output "$BUILD_DIR/physical-summary.json"
    echo "PHASE7_STAGE_PASS $stage"
} 2>&1 | tee "$BUILD_DIR/logs/$stage.log"
stage=phase7-mutations
{
    for audit in byte_prefix scalar shift data unary adjust segment stack_frame far strings io muldiv; do
        python3 -m "tools.audit_$audit" --build-dir "$BUILD_DIR"
    done
    echo "PHASE7_STAGE_PASS $stage"
} 2>&1 | tee "$BUILD_DIR/logs/$stage.log"
stage=arithmetic-and-port-comparators
{
    python3 -m tools.audit_muldiv_adapter --repo "$CORPUS" --executable "$EXE" --build-dir "$BUILD_DIR/arithmetic-comparator"
    python3 -m tools.audit_scalar_io --repo "$CORPUS" --build-dir "$BUILD_DIR/phase6"
    python3 -m tools.audit_combined_adapter --repo "$CORPUS" --executable "$EXE" --build-dir "$BUILD_DIR/combined-comparator"
    python3 -m tools.phase7_synthetic_io --executable "$EXE" --build-dir "$BUILD_DIR/synthetic-io"
    echo "PHASE7_STAGE_PASS $stage"
} 2>&1 | tee "$BUILD_DIR/logs/$stage.log"
stage=consistency
{
    python3 -m tools.phase6_inputs --manifest "$BUILD_DIR/inputs.json" --check
    python3 -m tools.phase7_policy --manifest "$BUILD_DIR/policy-inputs.json" --check
    python3 -m tools.phase6_development --ci-status
    echo "PHASE7_STAGE_PASS $stage"
} 2>&1 | tee "$BUILD_DIR/logs/$stage.log"
python3 -m tools.phase7_validation_receipt --build-dir "$BUILD_DIR"
if [[ "$mode" = complete ]]; then
    stage=independent-functional-review
    python3 -m tools.phase7_completion --receipt "$BUILD_DIR/execution-receipt.json"
else
    echo "PHASE7_EXECUTABLE_VALIDATION_PASS: independent functional closure review remains separate"
fi
