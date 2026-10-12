#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 -m tools.microcode.compile_microcode --check
python3 -m unittest discover -s tests -p 'test_microcode*.py' -v
python3 -m unittest tests.test_instruction_syntax -v
python3 -m tools.microcode.audit_microcode --output "${SPK286_BUILD_DIR:-build}/microcode-audit"
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
if [[ -f "$SINGLESTEP_ROOT/v1_real_mode/89.MOO.gz" || -f "$SINGLESTEP_ROOT/v1_real_mode/8B.MOO.gz" ]]; then
    python3 -m tools.run_singlestep --opcode 89 --opcode 8B --smoke
else
    echo "SINGLESTEP OPERAND SMOKE SKIP: 89/8B corpus is not present; run make singlestep-fetch"
fi
if [[ -f "$SINGLESTEP_ROOT/v1_real_mode/01.MOO.gz" ]]; then
    python3 -m tools.run_singlestep --alu --smoke
else
    echo "SINGLESTEP ALU SMOKE SKIP: external ALU corpus absent; release gate requires it"
fi
if [[ -f "$SINGLESTEP_ROOT/v1_real_mode/E8.MOO.gz" ]]; then
    python3 -m tools.run_singlestep --stack-control --smoke
else
    echo "SINGLESTEP STACK/CONTROL SMOKE SKIP: external corpus absent; release gate requires it"
fi
echo "TEST PASS"
