#!/usr/bin/env bash
set -euo pipefail

# Compare the exact same CPU-only stream against a named, immutable baseline.
# The archive and simulator products stay under the selected build directory.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build/register-throughput}"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
unit=spk286_register_throughput
if (( $# != 1 )); then
    echo "Usage: $0 baseline-commit" >&2
    exit 2
fi
revision="$(git rev-parse --verify "$1^{commit}")"
snapshot="$(mktemp -d "$BUILD_DIR/baseline-source.XXXXXX")"
git archive "$revision" | tar -x -C "$snapshot"
cp "sim/unit/${unit}_tb.sv" "$snapshot/sim/unit/"
SPK286_BUILD_DIR="$BUILD_DIR/baseline" bash "$snapshot/scripts/test_units.sh" both "$unit" > "$BUILD_DIR/baseline.log" 2>&1
SPK286_BUILD_DIR="$BUILD_DIR/current" bash scripts/test_units.sh both "$unit" > "$BUILD_DIR/current.log" 2>&1
python3 - "$BUILD_DIR" "$revision" <<'PY'
import json
from pathlib import Path
import re
import sys

directory, revision = Path(sys.argv[1]), sys.argv[2]
pattern = r'REGISTER THROUGHPUT mode=(\d) delayed=(\d) instructions=64 cycles=(\d+) fetches=(\d+) queue_empty=(\d+)'
captures = {}
for name in ('baseline', 'current'):
    rows = [tuple(map(int, row)) for row in re.findall(pattern, (directory / (name + '.log')).read_text())]
    if len(rows) != 12 or rows[:6] != rows[6:]:
        raise SystemExit(f'{name}: missing or unequal dual-simulator observations')
    captures[name] = rows[:6]
report = {'baseline_revision': revision, 'instructions_per_stream': 64, 'streams': []}
for before, after in zip(captures['baseline'], captures['current']):
    if before[:2] != after[:2] or after[2] >= before[2]:
        raise SystemExit(f'workload mismatch or missing improvement: {before} -> {after}')
    row = dict(mode=before[0], delayed=before[1], baseline_cycles=before[2],
               optimized_cycles=after[2], speedup=before[2]/after[2])
    report['streams'].append(row)
    print(f"mode={row['mode']} delayed={row['delayed']}: {before[2]} -> {after[2]} clocks, {row['speedup']:.3f}x")
(directory / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
print('REGISTER THROUGHPUT COMPARISON PASS: exact architectural checks and equal simulator captures')
PY
