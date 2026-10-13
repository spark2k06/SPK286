#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Inject isolated RTL faults into temporary copies of the sources and require
# the directed testbenches to reject every mutant. Production files are never
# modified.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build}/mutation"
cd "$ROOT_DIR"
mkdir -p "$BUILD_DIR"

for audit in operand_boundaries alu stack_control events byte_prefix scalar shift data unary \
             adjust segment stack_frame far strings io muldiv hold_lock_esc native; do
    echo "== audit_$audit"
    python3 -m "tools.audit_$audit" --build-dir "$BUILD_DIR"
done
for audit in double_fault null_ldtr task_late; do
    echo "== audit_$audit"
    rm -rf "${BUILD_DIR:?}/$audit"
    python3 -m "tools.audit_$audit" --output "$BUILD_DIR/$audit"
done
echo "MUTATION AUDIT PASS"
