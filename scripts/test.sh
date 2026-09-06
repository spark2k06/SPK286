#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./scripts/lint.sh
bash ./scripts/test_units.sh
./scripts/test_verilator.sh
./scripts/test_iverilog.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 -m tools.state_vectors
python3 -m tools.state_vectors --source tests/fixtures/state_vectors.json
SINGLESTEP_ROOT="${SPK286_SINGLESTEP_ROOT:-$ROOT_DIR/.cache/singlestep-80286}"
if [[ -f "$SINGLESTEP_ROOT/v1_real_mode/B8.MOO.gz" && -f "$SINGLESTEP_ROOT/revocation_list.txt" ]]; then
    python3 -m tools.run_singlestep --smoke
else
    echo "SINGLESTEP SMOKE SKIP: external corpus is not present; run make singlestep-fetch"
fi
echo "TEST PASS"
