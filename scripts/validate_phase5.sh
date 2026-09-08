#!/usr/bin/env bash
# Complete Phase 5 release gate; the entire inherited gate is mandatory.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export SPK286_BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build/phase5-final}"
mkdir -p "$SPK286_BUILD_DIR"
make phase4-check
make singlestep-stack-control-smoke singlestep-stack-control
python3 - "$SPK286_BUILD_DIR/singlestep" <<'PY'
import json
import shutil
import sys
from pathlib import Path
from tools.run_singlestep import OPCODES, MODRM_OPCODES, ALU_OPCODES, PHASE5_OPCODES
root=Path(sys.argv[1])
destination=root/'phase5-full-reports'
destination.mkdir(parents=True,exist_ok=True)
reports=[]
for opcode in OPCODES+MODRM_OPCODES+ALU_OPCODES+PHASE5_OPCODES:
    source=root/('full-reports' if opcode in OPCODES+MODRM_OPCODES else
                 'phase4-full-reports' if opcode in ALU_OPCODES else 'reports')/(opcode+'.json')
    data=json.loads(source.read_text())
    assert data['selection_skipped']==data['failed']==0, (opcode,'incomplete or failed family')
    assert data['discovered']==data['revoked']+data['prefix_skipped']+data['exception_skipped']+data['executed']
    assert data['selected']==data['executed']==data['passed']
    shutil.copy2(source,destination)
    reports.append(data)
inherited=sum(r['passed'] for r in reports if r['opcode'] not in PHASE5_OPCODES)
added=sum(r['passed'] for r in reports if r['opcode'] in PHASE5_OPCODES)
assert inherited==213980 and added==226594, (inherited,added)
summary={'inherited_passed':inherited,'phase5_passed':added,'total_passed':inherited+added,
         'discovered':sum(r['discovered'] for r in reports),'failed':0,'opcodes':reports}
(root/'phase5-summary.json').write_text(json.dumps(summary,indent=2,sort_keys=True)+'\n')
print(f'PHASE5_CORPUS PASS: {inherited} inherited + {added} new = {inherited+added}; no selected failures/skips')
PY
make stack-control-audit
make microcode-check
git diff --exit-code -- microcode/generated
echo "PHASE5_VALIDATION_PASS"
