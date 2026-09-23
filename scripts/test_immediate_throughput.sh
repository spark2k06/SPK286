#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build/immediate-throughput}"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
if (( $# != 1 )); then echo "Usage: $0 baseline-commit" >&2; exit 2; fi
revision="$(git rev-parse --verify "$1^{commit}")"
snapshot="$(mktemp -d "$BUILD_DIR/baseline-source.XXXXXX")"
git archive "$revision" | tar -x -C "$snapshot"
unit=spk286_immediate_throughput
cp "sim/unit/${unit}_tb.sv" "$snapshot/sim/unit/"
SPK286_BUILD_DIR="$BUILD_DIR/baseline" bash "$snapshot/scripts/test_units.sh" both "$unit" > "$BUILD_DIR/baseline.log" 2>&1
SPK286_BUILD_DIR="$BUILD_DIR/current" bash scripts/test_units.sh both "$unit" > "$BUILD_DIR/current.log" 2>&1
python3 - "$BUILD_DIR" "$revision" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys

directory, revision = Path(sys.argv[1]), sys.argv[2]
pattern = r'IMMEDIATE THROUGHPUT mode=(\d+) delayed=(\d) instructions=64 cycles=(\d+) fetches=(\d+) queue_empty=(\d+) reads=(\d+) writes=(\d+)'
captures = {}
for name in ('baseline', 'current'):
    rows = [tuple(map(int, row)) for row in re.findall(pattern, (directory/(name+'.log')).read_text())]
    if len(rows) != 52 or rows[:26] != rows[26:]:
        raise SystemExit(f'{name}: missing or unequal dual-simulator observations')
    captures[name] = rows[:26]
report = dict(baseline_revision=revision, instructions_per_stream=64, streams=[],
              log_sha256={n:hashlib.sha256((directory/(n+'.log')).read_bytes()).hexdigest() for n in captures})
for before, after in zip(captures['baseline'], captures['current']):
    assert before[:2] == after[:2] and before[5:] == after[5:], 'workload or operand traffic differs'
    if before[0] < 8:
        assert after[2] < before[2], f'no register speedup: {before} -> {after}'
    else:
        assert after == before, f'memory fallback changed: {before} -> {after}'
    row = dict(mode=before[0], delayed=before[1], baseline_cycles=before[2],
               optimized_cycles=after[2], speedup=before[2]/after[2])
    report['streams'].append(row)
    print(f"mode={row['mode']} delayed={row['delayed']}: {before[2]} -> {after[2]} clocks, {row['speedup']:.3f}x")
(directory/'comparison.json').write_text(json.dumps(report, indent=2)+'\n')
print('IMMEDIATE THROUGHPUT COMPARISON PASS: 16 faster register streams; 10 unchanged memory streams; both simulators')
PY
