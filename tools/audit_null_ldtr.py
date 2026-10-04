"""Reject isolated H16 null classification, readback and error defects."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from tools.null_ldtr_vectors import generate

from tools.rtl_sources import ordered_rtl_sources

ROOT=Path(__file__).resolve().parents[1]
PROBES=(
 ('exact-zero-task-null','spk286_task_switch_service',
  "if (task_loaded_ldtr[15:2] == 14'd0) begin",
  "if (task_loaded_ldtr == 16'h0000) begin"),
 ('canonicalize-explicit-null','spk286_micro_executor',
  'task_commit_ldtr_write ? task_loaded_ldtr : tmp0_q;',
  "task_commit_ldtr_write ? task_loaded_ldtr : descriptor_null_commit ? 16'd0 : tmp0_q;"),
 ('retain-error-rpl','spk286_task_switch_service',
  "fault_error_code_q <= task_loaded_ldtr & 16'hFFFC;",
  'fault_error_code_q <= task_loaded_ldtr;'),
 ('usable-null-task-cache','spk286_task_switch_service',
  "incoming_ldtr_class_q <= spk286_protected_pkg::DESC_INVALID;\n                        incoming_ldtr_valid_q <= 1'b0;",
  "incoming_ldtr_class_q <= spk286_protected_pkg::DESC_INVALID;\n                        incoming_ldtr_valid_q <= 1'b1;"),
)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    output=parser.parse_args().output.resolve()
    generate(output/'vectors')
    selected_names={'task-s0-e0-l0001','task-s1-e0-l0005','task-s2-e0-l0001',
                    'task-s4-e0-l0050','lldt-l0001'}
    selected=[row for row in (output/'vectors/vectors.txt').read_text().splitlines()
              if Path(row.split()[0]).stem in selected_names]
    assert len(selected)==5
    (output/'directed.txt').write_text('\n'.join(selected)+'\n')
    packages=[ROOT/'rtl/spk286_protected_pkg.sv',ROOT/'rtl/spk286_tss_pkg.sv']
    sources = ordered_rtl_sources(ROOT)
    originals={p:p.read_bytes() for p in sources}
    results=[]
    for name,module,old,new in [('pristine',None,None,None),('pristine-service',None,None,None),*PROBES]:
        out=output/name;out.mkdir(parents=True,exist_ok=True)
        # The executor already normalizes the service error at the CPU
        # boundary. Exercise the service contract directly for its raw code.
        service = name in ('pristine-service','retain-error-rpl')
        bench = 'spk286_task_switch_service_tb' if service else 'spk286_null_ldtr_tb'
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
                                '-s',bench,'-o',str(binary),
                                *map(str,inputs),str(ROOT/'sim/unit'/(bench+'.sv'))],
                               capture_output=True,text=True)
        (out/'build.log').write_text(compiled.stdout+compiled.stderr)
        assert compiled.returncode==0,name
        run=subprocess.run(['vvp',str(binary),*([] if service else ['+ldtr_vectors='+str(output/'directed.txt')])],
                           capture_output=True,text=True,timeout=60)
        (out/'run.log').write_text(run.stdout+run.stderr)
        if module: assert run.returncode!=0 and 'FATAL:' in run.stdout,name
        else: assert run.returncode==0 and ('TASK_SWITCH_SERVICE PASS: 102' if service else 'NULL_LDTR PASS: cases=10') in run.stdout
        results.append(dict(name=name,returncode=run.returncode,rejected=bool(module),
                            log_sha256=hashlib.sha256((out/'run.log').read_bytes()).hexdigest()))
        print('NULL_LDTR_MUTATION',name,'PASS',flush=True)
    assert all(p.read_bytes()==value for p,value in originals.items())
    (output/'summary.json').write_text(json.dumps(dict(validation='PASS',mutants=len(PROBES),
        results=results,source_sha256={p.relative_to(ROOT).as_posix():hashlib.sha256(v).hexdigest()
                                      for p,v in originals.items()}),indent=2)+'\n')


if __name__=='__main__': main()
