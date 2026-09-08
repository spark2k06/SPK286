"""Prevent an implemented subset from satisfying the complete Phase 7 gate."""
import json
from pathlib import Path
from tools.phase6_reports import unique_object
from tools.run_singlestep import SUPPORTED_OPCODES

def require_complete(path=Path('docs/phase7_forms.json')):
    doc=json.loads(path.read_text(),object_pairs_hook=unique_object)
    forms=doc['forms'];names=[f['opcode'] for f in forms]
    if len(names)!=326 or len(set(names))!=326:raise ValueError('incomplete/duplicate pinned form inventory')
    required={f['opcode'] for f in forms if f['scope']=='required'}
    if len(required)!=307:raise ValueError('required Phase 7 scope changed without a reviewed contract')
    missing=sorted(required-set(SUPPORTED_OPCODES))
    if missing:raise ValueError(f'{len(missing)} required opcode families remain unimplemented: '+','.join(missing))
if __name__=='__main__':
    try:require_complete()
    except (ValueError,OSError,KeyError,TypeError) as e:raise SystemExit(f'PHASE7_IMPLEMENTATION_PENDING: {e}')
