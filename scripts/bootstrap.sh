#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

packages=(git python3 python3-pip build-essential make cmake ninja-build verilator iverilog yosys gtkwave)
missing=()
for command_name in git python3 pip3 gcc g++ make verilator iverilog vvp yosys cmake ninja gtkwave; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done

if ((${#missing[@]} == 0)); then
    echo "SPK286 bootstrap: required tools already installed."
    ./scripts/env_check.sh
    exit 0
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "No apt-get found. Install these WSL packages manually: ${packages[*]}" >&2
    exit 1
fi

if [[ "$(id -u)" == "0" ]]; then
    apt_prefix=()
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    apt_prefix=(sudo)
else
    echo "Missing tools: ${missing[*]}" >&2
    echo "Run as WSL root or install this package set with sudo: ${packages[*]}" >&2
    exit 1
fi

echo "Installing missing WSL packages: ${packages[*]}"
"${apt_prefix[@]}" apt-get update
DEBIAN_FRONTEND=noninteractive "${apt_prefix[@]}" apt-get install -y "${packages[@]}"
./scripts/env_check.sh
