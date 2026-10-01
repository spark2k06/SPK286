#!/usr/bin/env python3
"""Exact source-guarded completion proof; no sequential or handshake change."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

REFERENCE = '13b467d'

def compact(s):
    return re.sub(r'\s+', '', re.sub(r'//[^\n]*|/\*.*?\*/', '', s, flags=re.S))

def assignment(s, n):
    return re.search(r'    assign '+n+r'\s*=.*?;', s, re.S).group(0)

def port(block, n):
    start = block.index('.'+n+'(')+len(n)+2
    depth=1
    for end in range(start,len(block)):
        depth += (block[end]=='(')-(block[end]==')')
        if depth==0: return block[start:end]
    raise ValueError(n)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('output',type=Path)
    out=ap.parse_args().output.resolve(); out.mkdir(parents=True,exist_ok=False)
    root=Path(__file__).resolve().parents[1]
    paths=['rtl/spk286.sv','rtl/spk286_operand.sv','rtl/spk286_micro_executor.sv']
    top,op,ex=[(root/p).read_text() for p in paths]
    old_top,old_op,old_ex=[subprocess.check_output(['git','show',REFERENCE+':'+p],cwd=root,text=True) for p in paths]
    bypass=assignment(top,'executor_operand_done')
    restored=top.replace(bypass,'').replace('logic unlimited_memory_done, executor_operand_done;','').replace('.operand_done(executor_operand_done)','.operand_done(operand_done)').replace('.unlimited_memory_done(unlimited_memory_done),','')
    assert compact(restored)==compact(old_top),'Unrelated top change'
    helper=assignment(op,'unlimited_memory_done')
    restored=op.replace(helper,'').replace('done, unlimited_memory_done','done')
    assert compact(restored)==compact(old_op),'Unrelated operand/sequential change'
    assert compact(ex)==compact(old_ex),'Executor changed'
    flags=['protected_descriptor_access','protected_event_access','protected_tss_access']
    states=['descriptor_active_q','event_gate_active_q','call_tss_active_q']
    for f,s in zip(flags,states):
        assert compact(assignment(ex,f))==f'assign{f}={s};'
    for n in ('operand_request','operand_select_rm'):
        assert compact(assignment(ex,n)).startswith('assign'+n+'='+'||'.join(states)+'||')
    fault_exprs=re.findall(r'    assign protected_access_fault\s*=.*?;',top,re.S)
    assert len(fault_exprs)==2
    for expr in fault_exprs:
        assert compact(expr).startswith('assignprotected_access_fault=operand_request&&operand_select_rm&&!operand_register_direct&&!protected_descriptor_access&&!protected_tss_access&&!protected_event_access&&')
    binding=re.search(r'spk286_operand operand \((.*?)\n    \);',top,re.S).group(1)
    text='''module miter(
input protected_descriptor_access, protected_event_access, protected_tss_access,
input request_rest, select_rest, fault_rest, reset, semantic_cancel, blocked,
input pending_q, memory_response_valid, operand_check, operand_byte,
input operand_register_direct, protected_call_stack_access, address_override,
input stack_request, vector_request, io_transfer, protected_segment_is_expand_down,
input [15:0] protected_msw, service_offset, segment_limit,
output mismatch);
wire operand_request, operand_select_rm, protected_access_fault;
wire request_valid, select_rm, register_direct, segment_expand_down;
wire request_check, request_byte, cancel, is_memory, within_limit, allowed;
wire [15:0] offset, op_limit;
wire done, operand_done, unlimited_memory_done, executor_operand_done;
assign operand_request=protected_descriptor_access||protected_event_access||protected_tss_access||request_rest;
assign operand_select_rm=protected_descriptor_access||protected_event_access||protected_tss_access||select_rest;
assign protected_access_fault=!protected_descriptor_access&&!protected_event_access&&!protected_tss_access&&fault_rest;
'''
    for name in ('request_valid','select_rm','register_direct','segment_expand_down','request_check','request_byte','cancel','offset'):
        text+='assign '+name+'='+port(binding,name)+';\n'
    text+='assign op_limit='+port(binding,'segment_limit')+';\n'
    for n in ('is_memory','within_limit','allowed','done'):
        text+=assignment(op,n).replace('segment_limit','op_limit')+'\n'
    text+='assign operand_done=done;\n'+helper+'\n'+bypass+'\nassign mismatch=executor_operand_done!=operand_done;\nendmodule\n'
    def run(src, stem, verify):
        p=out/(stem+'.sv'); p.write_text(src)
        cmd=f'read_verilog -sv {p}; prep -top miter; flatten; opt; sat '+('-verify ' if verify else '')+'-prove mismatch 0 -show-inputs'
        result=subprocess.run(['yosys','-p',cmd],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        (out/(stem+'.log')).write_text(result.stdout)
        return result
    result=run(text,'proof',True)
    assert result.returncode==0 and 'SUCCESS!' in result.stdout,'Completion equivalence failed'
    mutant=text.replace(helper,helper.replace('&& !blocked',''))
    assert mutant!=text
    result=run(mutant,'negative',False)
    assert result.returncode==0 and 'FAIL!' in result.stdout,'Blocked mutant not rejected'
    receipt={'schema':1,'status':'EXACT_PROTECTED_MEMORY_COMPLETION_EQUIVALENCE_PASS',
        'reference':REFERENCE,'negative_control':'REJECTED',
        'scope':'all two-state service flags, arbitrary pending/check/response/reset/cancel/blocked state and ordinary qualifiers; actual operand equations and top bindings; arbitrary remaining request/select/fault terms; unchanged sequential RTL and all old outputs',
        'sources_sha256':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths},
        'evidence_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*') if p.is_file()}}
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('PROTECTED_MEMORY_COMPLETION_FORMAL_PASS; blocked mutant rejected')

if __name__=='__main__': main()
