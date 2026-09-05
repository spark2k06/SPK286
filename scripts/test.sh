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
echo "TEST PASS"
