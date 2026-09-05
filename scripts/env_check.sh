#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

required=(git python3 pip3 gcc g++ make verilator iverilog vvp yosys cmake ninja gtkwave)
missing=()

echo "SPK286 environment"
echo "  repository: $ROOT_DIR"
echo "  host: $(uname -srm)"
echo "  git: $(git --version)"
echo "  python: $(python3 --version 2>&1)"

for command_name in "${required[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        missing+=("$command_name")
    fi
done

echo "  verilator: $(verilator --version 2>/dev/null || echo missing)"
echo "  iverilog: $(iverilog -V 2>&1 | head -n 1 || true)"
echo "  yosys: $(yosys --version 2>/dev/null || echo missing)"
echo "  cmake: $(cmake --version 2>/dev/null | head -n 1 || echo missing)"
echo "  ninja: $(ninja --version 2>/dev/null || echo missing)"
echo "  gtkwave: $(gtkwave --version 2>/dev/null | head -n 1 || echo missing)"

if command -v docker >/dev/null 2>&1; then
    echo "  docker: $(docker --version)"
    if docker image inspect raetro/quartus:mister >/dev/null 2>&1; then
        echo "  quartus image: raetro/quartus:mister available"
    else
        echo "  quartus image: raetro/quartus:mister not found"
    fi
else
    echo "  docker: unavailable (optional for the fast loop)"
fi

if ((${#missing[@]} != 0)); then
    echo "Missing required commands: ${missing[*]}" >&2
    echo "Run ./scripts/bootstrap.sh in WSL, or install the listed packages." >&2
    exit 1
fi

echo "ENV_CHECK PASS"
