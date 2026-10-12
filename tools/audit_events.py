# SPDX-License-Identifier: MIT
"""Prove event state/bus/lifecycle checks reject isolated functional RTL defects."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from tools.event_vectors import records

from tools.rtl_sources import ordered_rtl_sources

ROOT=Path(__file__).resolve().parents[1]
PROBES=(
    ('fault-start','spk286_events','spk286_event_lifecycle',
     '(repeat_boundary || (selected_kind == KIND_FAULT && instruction_active && !fault_new_task)) ? instruction_ip : ip','ip','precise source fault'),
    ('next-ip','spk286_events','spk286_event_lifecycle',
     'instruction_ip : ip;','instruction_ip : ip + 16\'d1;','INTR boundary frame'),
    ('frame-flags','spk286_events','spk286_event_instructions',
     '                event_flags <= flags;\n','                event_flags <= flags & 16\'hFCFF;\n','physical lane'),
    ('frame-cs','spk286_micro_executor','spk286_event_instructions',
     'read_event_cs ? event_cs : event_ip','read_event_cs ? event_ip : event_cs','physical lane'),
    ('ivt-stride','spk286_micro_executor','spk286_event_instructions',
     "{6'b000000, event_vector, 2'b00}","{7'b0000000, event_vector, 1'b0}",'ordered physical address'),
    ('vector-lane','spk286_biu','spk286_event_lifecycle',
     'ack_vector <= data_in[7:0];','ack_vector <= data_in[15:8];','complete selected event'),
    ('ack-pair','spk286_biu','spk286_event_lifecycle',
     "ack_active_q <= 1'b1; ack_second_q <= 1'b0;","ack_active_q <= 1'b1; ack_second_q <= 1'b1;",'HOLD waits for both INTA'),
    ('ack-ready','spk286_biu','spk286_event_lifecycle',
     'if (ready) begin','if (1\'b1) begin','HOLD waits for both INTA'),
    ('lock-chain','spk286_biu','spk286_event_lifecycle',
     "lock_chain_q <= 1'b1;","lock_chain_q <= 1'b0;",'INTA chain retains bus'),
    ('nmi-edge','spk286_events','spk286_event_lifecycle',
     'nmi && !nmi_previous_q','nmi','IRET releases pending NMI'),
    ('nmi-pending','spk286_events','spk286_event_lifecycle',
     'if (nmi_edge) nmi_pending','if (nmi_edge && !nmi_blocked) nmi_pending','second NMI edge latched'),
    ('nmi-block','spk286_events','spk286_event_lifecycle',
     '(nmi_pending || nmi_edge) && !nmi_blocked','(nmi_pending || nmi_edge)','second NMI edge latched while blocked'),
    ('nmi-unblock','spk286_events','spk286_event_lifecycle',
     "opcode == 8'hCF","opcode == 8'h00",'complete selected event'),
    ('sti-shadow','spk286_events','spk286_event_lifecycle',
     'intr && flags[9] && !sti_shadow && !ss_shadow && !(repeat_boundary && (repeat_ss_inhibit_q || repeat_sti_inhibit_q)) && !shutdown','intr && flags[9] && !ss_shadow && !(repeat_boundary && (repeat_ss_inhibit_q || repeat_sti_inhibit_q)) && !shutdown','STI shadow executes exactly'),
    ('tf-sample','spk286_events','spk286_event_lifecycle',
     'trap_sample_q <= flags[8];',"trap_sample_q <= 1'b0;",'complete selected event'),
    ('fault-retirement','spk286','spk286_event_instructions',
     '(event_completed && event_software)','event_completed','fault versus instruction retirement'),
    ('restore-system-bits','spk286_micro_executor','spk286_event_instructions',
     "iret_commit ? stack_flags_write_mask :","iret_commit ? 16'h7FD5 :",'exact CS IP FLAGS'),
    ('iret-cache','spk286','spk286_event_instructions',
     '.load_selector(context_commit ? context_cs : internal_segment_write ? internal_segment_data : segment_load_selector)',
     '.load_selector(internal_segment_write ? internal_segment_data : segment_load_selector)','exact CS IP FLAGS'),
    ('duplicate-delivery','spk286_events','spk286_event_instructions',
     "event_completed <= 1'b0;\n            nmi_previous_q",'event_completed <= event_completed;\n            nmi_previous_q','completion pulses do not repeat'),
    ('halt-state','spk286','spk286_event_instructions',
     '.halt_request(halt_request), .dispatch_ready',".halt_request(1'b0), .dispatch_ready",'halt/shutdown outcome'),
    ('cancel-temporaries','spk286_micro_executor','spk286_event_lifecycle',
     'if (reset || cancel || start) begin','if (reset || start) begin','debug cancel clears event dispatch and candidates'),
)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir',type=Path,default=Path(os.environ.get('SPK286_BUILD_DIR','build')))
    args=parser.parse_args()
    subprocess.run([sys.executable,'-m','tools.microcode.compile_microcode','--check'],check=True)
    output=args.build_dir.resolve()/'event-audit';output.mkdir(parents=True,exist_ok=True)
    vectors=output/'event-vectors.txt';rows=list(records())
    vectors.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    packages=[ROOT/'rtl/spk286_protected_pkg.sv',ROOT/'rtl/spk286_tss_pkg.sv']
    sources = ordered_rtl_sources(ROOT)
    originals={p:p.read_bytes() for p in sources}
    results=[]
    def execute(name,bench,mutation=None,reason=None):
        directory=output/name;directory.mkdir(parents=True,exist_ok=True)
        inputs=list(sources)
        if mutation:
            module,old,new=mutation;original=ROOT/'rtl'/(module+'.sv')
            text=originals[original].decode().replace("\r\n", "\n")
            if text.count(old)!=1:raise RuntimeError(f'{name}: mutation anchor must occur exactly once')
            changed=directory/original.name;changed.write_text(text.replace(old,new))
            inputs[inputs.index(original)]=changed
        binary=directory/'test.vvp'
        build=subprocess.run(['iverilog','-g2012','-Wall','-Irtl','-Isim/unit','-s',bench+'_tb','-o',str(binary),
                              *map(str,inputs),str(ROOT/'sim/unit'/(bench+'_tb.sv'))],cwd=ROOT,capture_output=True,text=True)
        (directory/'build.log').write_text(build.stdout+build.stderr)
        if build.returncode:raise RuntimeError(f'{name}: compiler failure is not a functional rejection')
        run=subprocess.run(['vvp',str(binary),f'+event_vectors={vectors}'],cwd=ROOT,capture_output=True,text=True,timeout=90)
        (directory/'run.log').write_text(run.stdout+run.stderr)
        if reason:
            if run.returncode==0 or reason not in run.stdout+run.stderr:
                raise RuntimeError(f'{name}: intended assertion did not reject the mutant; see {directory}/run.log')
        elif run.returncode or 'PASS:' not in run.stdout:raise RuntimeError(f'{name}: pristine test failed')
        results.append({'name':name,'bench':bench,'status':run.returncode,'expected_assertion':reason})
        print(f'EVENT_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}',flush=True)
    for bench in ('spk286_event_instructions','spk286_event_lifecycle'):execute('pristine-'+bench,bench)
    for name,module,bench,old,new,reason in PROBES:execute(name,bench,(module,old,new),reason)
    if any(p.read_bytes()!=data for p,data in originals.items()):raise RuntimeError('production source bytes changed during mutation audit')
    summary={'validation':'PASS','mutants':len(PROBES),'pristine':2,'results':results,
             'source_sha256':{p.relative_to(ROOT).as_posix():hashlib.sha256(data).hexdigest() for p,data in originals.items()}}
    (output/'summary.json').write_text(json.dumps(summary,indent=2,sort_keys=True)+'\n')
    print(f'EVENT_AUDIT PASS: {len(PROBES)} rejected RTL mutants; 2 pristine benches; production bytes unchanged')


if __name__=='__main__':main()
