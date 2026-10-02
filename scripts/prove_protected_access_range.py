#!/usr/bin/env python3
"""Exact proof of the top-level protected-access fault including offset priority."""
import argparse, hashlib, json, re, subprocess
from pathlib import Path

REFERENCE = 'f029491'
def compact(s):
    return re.sub(r'\s+', '', re.sub(r'//[^\n]*|/\*.*?\*/', '', s, flags=re.S))
def assignment(s, name):
    return re.search(r'    assign '+name+r'\s*=.*?;', s, re.S).group(0)

ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('output', type=Path)
out=ap.parse_args().output.resolve(); out.mkdir(parents=True, exist_ok=False)
root=Path(__file__).resolve().parents[1]
path=root/'rtl/spk286.sv'; cur=path.read_text()
old=subprocess.check_output(['git', 'show', REFERENCE+':rtl/spk286.sv'], cwd=root, text=True)
old_fault=assignment(old, 'protected_access_fault')
new_fault=assignment(cur, 'protected_access_fault')
helper=re.search(r'    function automatic logic protected_range_exceeded\(.*?endfunction', cur, re.S).group(0)
declaration='    logic protected_selected_range_fault, protected_call_range_fault;'
selected=assignment(cur, 'protected_selected_range_fault')
call=assignment(cur, 'protected_call_range_fault')
restored=cur.replace(helper, '').replace(declaration, '').replace(selected, '').replace(call, '')
restored=restored.replace(new_fault, old_fault)
assert compact(restored)==compact(old), 'Unrelated top-level or sequential change'
inputs='''module miter(
input operand_request, operand_select_rm, operand_register_direct,
input protected_descriptor_access, protected_tss_access, protected_event_access,
input io_transfer, vector_request, protected_call_stack_access,
input protected_call_stack_expand_down, protected_segment_is_loaded,
input protected_segment_is_valid, protected_segment_is_present,
input protected_segment_is_code, protected_segment_is_readable,
input protected_segment_is_writable, protected_segment_is_expand_down,
input operand_byte, operand_write, stack_request, address_override,
input [1:0] service_segment,
input [15:0] address_offset, vector_offset, stack_offset, operand_offset,
input [15:0] protected_call_stack_limit, selected_segment_limit,
output mismatch);
wire [15:0] service_offset;
wire old_fault, protected_access_fault;
wire protected_selected_range_fault, protected_call_range_fault;
'''
text=inputs+helper+'\n'+assignment(old,'service_offset')+'\n'
text+=old_fault.replace('assign protected_access_fault', 'assign old_fault')+'\n'
text+=selected+'\n'+call+'\n'+new_fault+'\n'
text+='assign mismatch=old_fault!=protected_access_fault;\nendmodule\n'
def run(src, name, verify):
    p=out/(name+'.sv'); p.write_text(src)
    cmd=f'read_verilog -sv {p}; prep -top miter; flatten; opt; sat '+('-verify ' if verify else '')+'-prove mismatch 0 -show-inputs'
    r=subprocess.run(['yosys','-p',cmd], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out/(name+'.log')).write_text(r.stdout)
    return r
r=run(text,'proof',True)
assert r.returncode==0 and 'SUCCESS!' in r.stdout, 'Protected-access equivalence failed'
mutant=text.replace(selected, selected.replace('stack_request ?', '1\'b0 ?'))
assert mutant!=text
r=run(mutant,'negative',False)
assert r.returncode==0 and 'FAIL!' in r.stdout, 'Offset-priority mutant not rejected'
(out/'receipt.json').write_text(json.dumps({
    'status':'EXACT_PROTECTED_ACCESS_RANGE_EQUIVALENCE_PASS', 'reference':REFERENCE,
    'scope':'all two-state offset/limit/width/access/priority/qualifier combinations, including overlapping stack/address/vector/I-O requests; actual service_offset and fault RTL; all other top-level and sequential RTL unchanged',
    'negative_control':'STACK_PRIORITY_MUTANT_REJECTED',
    'source_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
    'evidence_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()}
},indent=2)+'\n')
print('PROTECTED_ACCESS_RANGE_FORMAL_PASS; offset-priority mutant rejected')
