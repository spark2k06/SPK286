"""Check that focused task-publication observations reject isolated publication defects."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from tools.task_late_vectors import generate

from tools.rtl_sources import ordered_rtl_sources

ROOT=Path(__file__).resolve().parents[1]
PROBES=(
 ('retain-outgoing-caches','spk286_protected_state',
  'if (task_load_en) begin',"if (1'b0 && task_load_en) begin"),
 ('omit-cache-stages','spk286_task_switch_service',
  'assign cache_commit = state_q == ST_SEG_ACTIVE && segment_commit_valid;',
  "assign cache_commit = 1'b0;"),
 ('validate-before-publication','spk286_task_switch_service',
  'if (state_loaded) state_q <= ST_LDTR_CHECK;',"if (1'b1) state_q <= ST_LDTR_CHECK;"),
 ('old-exception-context','spk286_events',
  '(selected_kind == KIND_FAULT && instruction_active && !fault_new_task)) ? instruction_ip : ip',
  '(selected_kind == KIND_FAULT && instruction_active)) ? instruction_ip : ip'),
 ('wrong-cache-index','spk286_micro_executor',
  'task_commit_segment_write ? task_cache_commit_index :',
  "task_commit_segment_write ? 2'd0 :"),
)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    output=parser.parse_args().output.resolve()
    generate(output/'vectors')
    rows=(output/'vectors/vectors.txt').read_text().splitlines()
    selected=[row for row in rows if Path(row.split()[0]).stem in
              ('s0-e0-a0-h0','s7-e0-a0-h1','s3-e0-a1-h0','s5-e0-a1-h0')]
    assert len(selected)==4
    (output/'directed.txt').write_text('\n'.join(selected)+'\n')
    packages=[ROOT/'rtl/spk286_protected_pkg.sv',ROOT/'rtl/spk286_tss_pkg.sv']
    sources = ordered_rtl_sources(ROOT)
    originals={p:p.read_bytes() for p in sources}
    results=[]
    for name,module,old,new in [('pristine',None,None,None),*PROBES]:
        out=output/name;out.mkdir(parents=True,exist_ok=True)
        inputs=list(sources)
        if module:
            original=ROOT/'rtl'/(module+'.sv')
            text=originals[original].decode().replace('\r\n','\n')
            assert text.count(old)==1,(name,text.count(old))
            replacement=out/original.name
            replacement.write_text(text.replace(old,new))
            inputs[inputs.index(original)]=replacement
        binary=out/'probe.vvp'
        compiled=subprocess.run(['iverilog','-g2012','-I'+str(ROOT/'rtl'),'-I'+str(ROOT/'sim/unit'),
                                '-s','spk286_task_late_publication_tb','-o',str(binary),
                                *map(str,inputs),str(ROOT/'sim/unit/spk286_task_late_publication_tb.sv')],
                               capture_output=True,text=True)
        (out/'build.log').write_text(compiled.stdout+compiled.stderr)
        assert compiled.returncode==0,name
        run=subprocess.run(['vvp',str(binary),'+task_vectors='+str(output/'directed.txt')],capture_output=True,text=True,timeout=600)
        (out/'run.log').write_text(run.stdout+run.stderr)
        if module:
            assert run.returncode!=0 and 'FATAL:' in run.stdout,name
        else:
            assert run.returncode==0 and 'TASK_LATE_PUBLICATION PASS: cases=4' in run.stdout
        results.append({'name':name,'returncode':run.returncode,'rejected':bool(module),
                        'log_sha256':hashlib.sha256((out/'run.log').read_bytes()).hexdigest()})
        print('TASK_LATE_MUTATION',name,'PASS',flush=True)
    assert all(p.read_bytes()==value for p,value in originals.items())
    (output/'summary.json').write_text(json.dumps({'validation':'PASS','mutants':len(PROBES),
        'results':results,'source_sha256':{p.relative_to(ROOT).as_posix():hashlib.sha256(v).hexdigest() for p,v in originals.items()}},indent=2)+'\n')

if __name__=='__main__':main()
