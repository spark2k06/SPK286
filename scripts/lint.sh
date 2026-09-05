#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

command -v verilator >/dev/null 2>&1 || {
    echo "verilator is required; run ./scripts/bootstrap.sh" >&2
    exit 1
}

verilator --lint-only --language 1800-2012 --Wall \
    --top-module spk286 -Irtl rtl/*.sv
verilator --lint-only --language 1800-2012 --Wall \
    --top-module spk286_registers -Irtl rtl/spk286_registers.sv
verilator --lint-only --language 1800-2012 --Wall \
    --top-module spk286_segments -Irtl rtl/spk286_segments.sv
verilator --lint-only --language 1800-2012 --Wall \
    --top-module spk286_fetch -Irtl rtl/spk286_fetch.sv
echo "LINT PASS"
