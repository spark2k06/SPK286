#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

command -v docker >/dev/null 2>&1 || {
    echo "docker is required to inspect the Quartus container" >&2
    exit 1
}

docker image inspect raetro/quartus:mister >/dev/null 2>&1 || {
    echo "Docker image raetro/quartus:mister is not available locally" >&2
    exit 1
}

docker run --rm raetro/quartus:mister quartus_sh --version
echo "QUARTUS_INFO PASS"
