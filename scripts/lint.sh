#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

command -v verilator >/dev/null 2>&1 || {
    echo "verilator is required; run ./scripts/bootstrap.sh" >&2
    exit 1
}

verilator --lint-only --language 1800-2012 --Wall \
    --top-module spk286 -Irtl rtl/spk286.sv
echo "LINT PASS"
