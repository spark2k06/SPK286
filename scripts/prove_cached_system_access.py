#!/usr/bin/env python3
"""Exact cached six-byte system range and shared protected-access fault proof."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

REFERENCE = 'a1bc502'


def compact(source):
    return re.sub(r'\s+', '', re.sub(r'//[^\n]*|/\*.*?\*/', '', source, flags=re.S))


def assignment(source, name):
    return re.search(r'    assign '+name+r'(?:\[[^\]]*\])?\s*=.*?;', source, re.S).group(0)


def port(block, name):
    start = block.index('.'+name+'(')+len(name)+2
    depth = 1
    for end in range(start, len(block)):
        depth += (block[end] == '(')-(block[end] == ')')
        if depth == 0:
            return block[start:end]
    raise ValueError(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    out = parser.parse_args().output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    paths = ('rtl/spk286.sv', 'rtl/spk286_micro_executor.sv')
    top, executor = [(root/p).read_text() for p in paths]
    old_top, old_executor = [subprocess.check_output(
        ['git', 'show', REFERENCE+':'+p], cwd=root, text=True) for p in paths]
    old_helper = re.search(r'    // Compare cache ranges before selecting.*?'
        r'    assign parallel_operand_within_limit\s*=.*?;', old_top, re.S).group(0)
    helper = re.search(r'    // Compare cache ranges before selecting.*?'
        r'    assign parallel_system_cache_fault\s*=.*?;', top, re.S).group(0)
    system_ranges = assignment(helper, 'operand_system_ranges')
    restored_helper = helper.replace(system_ranges, '').replace(
        '    (* keep *) logic [3:0] operand_system_ranges;', '').replace(
        'parallel_operand_within_limit, parallel_system_cache_fault', 'parallel_operand_within_limit').replace(
        assignment(helper, 'parallel_system_cache_fault'), '')
    assert compact(restored_helper) == compact(old_helper), 'Generic operand cache checks changed'
    old_range = assignment(old_top, 'protected_selected_range_fault')
    new_range = assignment(top, 'protected_selected_range_fault')
    assert compact(new_range) == 'assignprotected_selected_range_fault=!parallel_operand_within_limit;'
    instance = '''    spk286_micro_executor #(
`ifdef SPK286_P05_PARALLEL_LIMIT_CHECK
        .USE_PARALLEL_SYSTEM_LIMIT(1'b1)
`else
        .USE_PARALLEL_SYSTEM_LIMIT(1'b0)
`endif
    ) micro_executor (
`ifdef SPK286_P05_PARALLEL_LIMIT_CHECK
        .parallel_system_limit_fault(parallel_system_cache_fault),
`else
        .parallel_system_limit_fault(1'b0),
`endif'''
    assert instance in top
    restored_top = top.replace(helper, old_helper).replace(new_range, old_range).replace(
        instance, '    spk286_micro_executor micro_executor (')
    assert compact(restored_top) == compact(old_top), 'Unrelated top/sequential change'
    old_system = assignment(old_executor, 'system_limit_fault')
    new_system = assignment(executor, 'system_limit_fault')
    assert compact(new_system.replace('USE_PARALLEL_SYSTEM_LIMIT ? parallel_system_limit_fault : ', '')) == compact(old_system), 'Baseline system-range expression changed'
    restored_executor = executor.replace(new_system, old_system).replace(
        "module spk286_micro_executor #(parameter bit USE_PARALLEL_SYSTEM_LIMIT = 1'b0) (",
        'module spk286_micro_executor (').replace(
        '    input logic segment_expand_down, parallel_system_limit_fault,',
        '    input logic segment_expand_down,')
    assert compact(restored_executor) == compact(old_executor), 'Unrelated executor/sequential change'
    function = re.search(r'    function automatic logic protected_range_exceeded\(.*?endfunction', top, re.S).group(0)
    binding = re.search(r'    spk286_micro_executor micro_executor \((.*?)\n    \);', old_top, re.S).group(1)
    proof = '''module miter(
input [15:0] protected_msw, address_offset, vector_offset, stack_offset, operand_offset,
input [63:0] protected_segment_limits, real_segment_limits,
input [31:0] protected_segment_access, real_segment_access_state,
input [3:0] protected_segment_protected, protected_segment_valid, protected_segment_present,
input [1:0] selected_segment_index, service_segment,
input [15:0] protected_call_stack_limit,
input operand_request, operand_select_rm, operand_register_direct, operand_write, operand_byte,
input protected_event_access, protected_descriptor_access, protected_tss_access,
input protected_call_stack_access, protected_call_stack_expand_down,
input vector_request, io_transfer, address_override, stack_request, system_table_operation,
output mismatch);
wire [15:0] selected_segment_limit, segment_limit, effective_offset;
wire [7:0] selected_segment_access;
wire protected_segment_is_loaded, protected_segment_is_valid, protected_segment_is_present;
wire protected_segment_is_code, protected_segment_is_readable, protected_segment_is_writable;
wire protected_segment_is_expand_down, protected_call_range_fault, segment_expand_down;
wire old_selected_fault, protected_selected_range_fault, old_access_fault, protected_access_fault;
wire old_system_fault, system_limit_fault, parallel_system_limit_fault;
localparam USE_PARALLEL_SYSTEM_LIMIT=1'b1;
'''+function+'\n'
    for name in ('selected_segment_limit', 'selected_segment_access', 'segment_limit',
                 'protected_segment_is_loaded', 'protected_segment_is_valid', 'protected_segment_is_present',
                 'protected_segment_is_code', 'protected_segment_is_readable', 'protected_segment_is_writable',
                 'protected_segment_is_expand_down', 'protected_call_range_fault'):
        proof += assignment(old_top, name)+'\n'
    for name in ('effective_offset', 'segment_expand_down'):
        proof += 'assign '+name+'='+port(binding, name)+';\n'
    proof += old_range.replace('protected_selected_range_fault', 'old_selected_fault')+'\n'
    old_fault = assignment(old_top, 'protected_access_fault')
    proof += old_fault.replace('protected_selected_range_fault', 'old_selected_fault').replace(
        'assign protected_access_fault', 'assign old_access_fault')+'\n'
    proof += old_system.replace('assign system_limit_fault', 'assign old_system_fault')+'\n'
    proof += helper+'\n'+new_range+'\n'+assignment(top, 'protected_access_fault')+'\n'
    proof += 'assign parallel_system_limit_fault=parallel_system_cache_fault;\n'+new_system+'\n'
    proof += 'assign mismatch=(old_access_fault!=protected_access_fault)||(old_system_fault!=system_limit_fault);\nendmodule\n'

    def run(source, name, verify):
        path = out/(name+'.sv')
        path.write_text(source)
        command = (f'read_verilog -sv {path}; prep -top miter; flatten; opt; sat '+
                   ('-verify ' if verify else '')+'-prove mismatch 0 -show-inputs')
        result = subprocess.run(['yosys', '-p', command], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (out/(name+'.log')).write_text(result.stdout)
        return result

    result = run(proof, 'proof', True)
    assert result.returncode == 0 and 'SUCCESS!' in result.stdout, 'Cached system/access equivalence failed'
    for name, old, new in (
        ('overflow-negative', "operand_offset <= cache_limit || operand_offset > 16'hFFFA", 'operand_offset <= cache_limit'),
        ('offset-negative', 'operand_regular_ranges[selected_segment_index];', 'operand_stack_ranges[selected_segment_index];')):
        negative = proof.replace(old, new)
        assert negative != proof
        result = run(negative, name, False)
        assert result.returncode == 0 and 'FAIL!' in result.stdout, 'Negative control not rejected: '+name
    (out/'receipt.json').write_text(json.dumps({
        'status': 'EXACT_CACHED_SYSTEM_AND_SHARED_PROTECTED_ACCESS_EQUIVALENCE_PASS',
        'reference': REFERENCE,
        'scope': 'all two-state mode/cache/width/offset/selector/permission/request states and arbitrary overlapping service flags; actual PE-loaded qualification and micro-executor binding; full non-wrapping six-byte table range; generic operand cache checks and all other sequential/output RTL unchanged; default/baseline system parameter retains old expression',
        'negative_controls': ['EXPAND_DOWN_OVERFLOW_MUTANT_REJECTED', 'WRONG_ORDINARY_OFFSET_MUTANT_REJECTED'],
        'source_sha256': {p: hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths},
        'evidence_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in out.iterdir() if p.is_file()}
    }, indent=2)+'\n')
    print('CACHED_SYSTEM_ACCESS_FORMAL_PASS; both mutants rejected')


if __name__ == '__main__':
    main()
