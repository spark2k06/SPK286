#!/usr/bin/env python3
"""Exact equivalence of all GPR writeback data priorities, including overlaps."""
import argparse,hashlib,json,re,subprocess
from pathlib import Path
REFERENCE='c4a0761'
def compact(s):return re.sub(r'\s+','',re.sub(r'//[^\n]*|/\*.*?\*/','',s,flags=re.S))
ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('output',type=Path)
out=ap.parse_args().output.resolve();out.mkdir(parents=True,exist_ok=False)
root=Path(__file__).resolve().parents[1];path=root/'rtl/spk286_micro_executor.sv'
cur=path.read_text();old=subprocess.check_output(['git','show',REFERENCE+':rtl/spk286_micro_executor.sv'],cwd=root,text=True)
old_assignment=re.search(r'    assign sequential_gpr_write_data\s*=.*?;',old,re.S).group(0)
helper=re.search(r'    logic \[19:0\] gpr_data_requests;.*?    assign sequential_gpr_write_data\s*=.*?;',cur,re.S).group(0)
assert compact(cur.replace(helper,old_assignment))==compact(old),'Unrelated executor/sequential change'
text='''module miter(
input task_commit_gpr_write,iret_outer_sp_commit,retf_outer_sp_commit,
input return_same_sp_commit,call_gate_sp_commit,segment_pop_sp_commit,
input descriptor_result_write,fixed_result_write,string_index_write,
input string_count_write,string_write_acc,add_allocation_arch,frame_write_gpr,
input allocate_stack,move_source,stack_arch_write,count_operation,result_to_dst,move_word,
input commit_context,allocation_valid_q,write_result_dx,
input [3:0] task_commit_phase_q,
input [127:0] task_loaded_gpr,
input [15:0] iret_outer_sp_q,allocation_q,stack_cursor_q,descriptor_result_data,
input [15:0] auxiliary_q,tmp0_q,tmp1_q,tmp2_q,string_index,string_delta,
input [15:0] count_value,stack_pointer,stack_next_sp,operand_gpr_write_data,architectural_flags,
output mismatch);
wire [15:0] old_data,sequential_gpr_write_data;
'''+old_assignment.replace('sequential_gpr_write_data','old_data')+'\n'+helper+'\nassign mismatch=old_data!=sequential_gpr_write_data;\nendmodule\n'
def run(src,name,verify):
 p=out/(name+'.sv');p.write_text(src)
 cmd=f'read_verilog -sv {p}; prep -top miter; flatten; opt; sat '+('-verify ' if verify else '')+'-prove mismatch 0 -show-inputs'
 r=subprocess.run(['yosys','-p',cmd],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (out/(name+'.log')).write_text(r.stdout);return r
r=run(text,'proof',True)
assert r.returncode==0 and 'SUCCESS!' in r.stdout,'GPR data equivalence failed'
mutant=text.replace('!(|gpr_data_requests[gpr_data_index-1:0])',"1'b1")
assert mutant!=text
r=run(mutant,'negative',False)
assert r.returncode==0 and 'FAIL!' in r.stdout,'Overlapping-priority mutant not rejected'
(out/'receipt.json').write_text(json.dumps({
 'status':'EXACT_GPR_DATA_PRIORITY_EQUIVALENCE_PASS','reference':REFERENCE,
 'scope':'all two-state overlapping priority flags and all data values, including the full task-register slice, all arithmetic, flags and phase values; actual RTL; all other executor/sequential RTL unchanged',
 'negative_control':'OVERLAPPING_PRIORITY_MUTANT_REJECTED',
 'source_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
 'evidence_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()}
},indent=2)+'\n')
print('GPR_PRIORITY_MUX_FORMAL_PASS; overlapping-priority mutant rejected')
