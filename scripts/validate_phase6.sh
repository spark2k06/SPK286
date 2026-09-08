#!/usr/bin/env bash
# Shared executable gate with a separate, unchanged architectural release check.
set -euo pipefail
mode="${1:-architectural}"
case "$mode" in architectural|executable) ;; *) echo "Unknown Phase 6 gate: $mode" >&2; exit 2;; esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export SPK286_BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build/phase6-final}"
if [[ -e "$SPK286_BUILD_DIR" ]]; then
    echo "PHASE6_VALIDATION_FAIL: choose a previously absent build directory" >&2
    exit 1
fi
mkdir -p "$SPK286_BUILD_DIR"
stage=inputs
trap 'status=$?; echo "PHASE6_VALIDATION_FAIL: stage=$stage status=$status" >&2; exit "$status"' ERR
python3 -m tools.phase6_inputs --manifest "$SPK286_BUILD_DIR/inputs.json"
stage=inherited
# Includes double regeneration, frozen/active audits, every Python test,
# lint, all benches in both simulators, dual smoke/state/waveforms, MCL86,
# full inherited hardware, full upstream/EXCP/RMSK parser/comparator audit,
# all 24 inherited RTL mutants, failure propagation, synthesis and regression.
make phase5-check
stage=event-hardware
make singlestep-events-smoke singlestep-phase6
mkdir "$SPK286_BUILD_DIR/singlestep/phase6-full-reports"
cp "$SPK286_BUILD_DIR/singlestep/reports/"*.json "$SPK286_BUILD_DIR/singlestep/phase6-full-reports/"
python3 -m tools.phase6_reports --reports "$SPK286_BUILD_DIR/singlestep/phase6-full-reports" --output "$SPK286_BUILD_DIR/singlestep/phase6-summary.json"
stage=event-mutations
make event-audit
stage=event-traces
vvp "$SPK286_BUILD_DIR/iverilog/spk286_event_lifecycle_tb/spk286_event_lifecycle_tb.vvp" +trace="$SPK286_BUILD_DIR/traces/intr-lifecycle.vcd"
python3 -m tools.inspect_event_traces --directory "$SPK286_BUILD_DIR/singlestep-audit" --intr-trace "$SPK286_BUILD_DIR/traces/intr-lifecycle.vcd" --output "$SPK286_BUILD_DIR/traces/events.json"
stage=final-regression
make regression verify-failure data-smoke
stage=consistency
make microcode-check
git diff --exit-code -- microcode/generated
python3 -m tools.phase6_inputs --manifest "$SPK286_BUILD_DIR/inputs.json" --check
stage=development-evidence
python3 -m tools.phase6_development
echo "PHASE6_EXECUTABLE_VALIDATION_PASS"
if [[ "$mode" == architectural ]]; then
    stage=architectural-evidence
    python3 -m tools.phase6_evidence
    echo "PHASE6_VALIDATION_PASS"
fi
