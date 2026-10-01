#!/usr/bin/env python3
"""Prove the actual outer-return range rewrite, including 17-bit wrapping."""
import argparse,hashlib,json,re,subprocess
from pathlib import Path
REFERENCE='93e2aa2'
HELPERS=('iret_outer_sum_bits','iret_outer_carry_bits','iret_outer_last_byte')
def assignment(s,n):return re.search(r'    assign '+n+r'\s*=.*?;',s,re.S).group(0)
def compact(s):return re.sub(r'\s+','',re.sub(r'//[^\n]*|/\*.*?\*/','',s,flags=re.S))
ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('output',type=Path)
out=ap.parse_args().output.resolve();out.mkdir(parents=True,exist_ok=False)
root=Path(__file__).resolve().parents[1];p=root/'rtl/spk286_micro_executor.sv'
cur=p.read_text();old=subprocess.check_output(['git','show',REFERENCE+':rtl/spk286_micro_executor.sv'],cwd=root,text=True)
restored=cur.replace(assignment(cur,'iret_outer_range_fault'),assignment(old,'iret_outer_range_fault'))
for n in HELPERS:restored=restored.replace(assignment(cur,n),'')
restored=restored.replace('logic [16:0] '+', '.join(HELPERS)+';','')
assert compact(restored)==compact(old),'Unrelated executor/sequential change'
text='''module miter(input [15:0] return_stack_pointer,allocation_q,stack_segment_limit,
input [7:0] stack_segment_access,input allocation_valid_q,iret_outer_frame_operation,iret_outer_required,
input [1:0] iret_outer_phase_q,output mismatch);
wire [16:0] iret_outer_sum_bits,iret_outer_carry_bits,iret_outer_last_byte;
wire iret_outer_range_fault,old_fault;
'''
text+=assignment(old,'iret_outer_range_fault').replace('iret_outer_range_fault','old_fault')+'\n'
text+='\n'.join(assignment(cur,n) for n in HELPERS+('iret_outer_range_fault',))
text+='\nassign mismatch=iret_outer_range_fault!=old_fault;\nendmodule\n'
def run(s,stem,verify):
 q=out/(stem+'.sv');q.write_text(s)
 cmd=f'read_verilog -sv {q}; prep -top miter; flatten; opt; sat '+('-verify ' if verify else '')+'-prove mismatch 0 -show-inputs'
 r=subprocess.run(['yosys','-p',cmd],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (out/(stem+'.log')).write_text(r.stdout);return r
r=run(text,'proof',True);assert r.returncode==0 and 'SUCCESS!' in r.stdout
bad=text.replace('wire [16:0] iret_outer_sum_bits','wire [17:0] iret_outer_sum_bits')
bad=bad.replace(assignment(cur,'iret_outer_last_byte'),"assign iret_outer_last_byte={2'b0,return_stack_pointer}+{2'b0,allocation_valid_q ? allocation_q : 16'd0}+18'd3;")
assert bad!=text
r=run(bad,'negative-width',False);assert r.returncode==0 and 'FAIL!' in r.stdout,'18-bit wrapping mutant not rejected'
(out/'receipt.json').write_text(json.dumps({'status':'EXACT_OUTER_FRAME_SUM_EQUIVALENCE_PASS','reference':REFERENCE,'scope':'all two-state SP/allocation/limit/access/enable/phase values; actual old and new range equations; original 17-bit modulo arithmetic retained; all other executor expressions and sequential logic unchanged','negative_control':'18_BIT_NONWRAPPING_MUTANT_REJECTED','source_sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'evidence_sha256':{q.name:hashlib.sha256(q.read_bytes()).hexdigest() for q in out.iterdir() if q.is_file()}},indent=2)+'\n')
print('OUTER_FRAME_SUM_FORMAL_PASS; 18-bit wrapping mutant rejected')
