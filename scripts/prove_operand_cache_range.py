#!/usr/bin/env python3
"""Prove early cache comparisons against the actual previous operand binding."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

REFERENCE = 'c4a0761'


def assignment(source, name):
    return re.search(r'    assign '+name+r'\s*=.*?;', source, re.S).group(0)


def port(block, name):
    start = block.index('.'+name+'(')+len(name)+2
    depth = 1
    for end in range(start, len(block)):
        depth += (block[end] == '(')-(block[end] == ')')
        if depth == 0:
            return block[start:end]
    raise ValueError(name)


def compact(source):
    return re.sub(r'\s+', '', re.sub(r'//[^\n]*|/\*.*?\*/', '', source, flags=re.S))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    out = parser.parse_args().output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    paths = ('rtl/spk286.sv', 'rtl/spk286_operand.sv')
    top, operand = [(root/p).read_text() for p in paths]
    old_top, old_operand = [subprocess.check_output(
        ['git', 'show', REFERENCE+':'+p], cwd=root, text=True) for p in paths]
    helper = re.search(r'    // Compare cache ranges before selecting.*?'
                       r'    assign parallel_operand_within_limit\s*=.*?;', top, re.S).group(0)
    instance = re.search(r'    spk286_operand #\(.*?\n    \) operand \(\n'
                         r'`ifdef SPK286_P05_PARALLEL_LIMIT_CHECK\n'
                         r'        \.parallel_within_limit\(parallel_operand_within_limit\),\n'
                         r'`else\n        \.parallel_within_limit\(1\x27b0\),\n`endif', top, re.S).group(0)
    restored = top.replace(helper, '').replace(instance, '    spk286_operand operand (')
    assert compact(restored) == compact(old_top), 'Unrelated top-level/sequential change'
    assert '.USE_PARALLEL_RANGE(1\x27b1)' in instance
    assert '.USE_PARALLEL_RANGE(1\x27b0)' in instance
    new_assignment = assignment(operand, 'within_limit')
    old_assignment = assignment(old_operand, 'within_limit')
    assert compact(new_assignment).startswith(
        'assignwithin_limit=USE_PARALLEL_RANGE?parallel_within_limit:')
    restored_operand = operand.replace(new_assignment, old_assignment).replace(
        "module spk286_operand #(parameter bit USE_PARALLEL_RANGE = 1'b0) (",
        'module spk286_operand (').replace(
        '    input  logic segment_expand_down, parallel_within_limit,',
        '    input  logic segment_expand_down,')
    assert compact(restored_operand) == compact(old_operand), 'Unrelated operand/sequential change'
    binding = re.search(r'    spk286_operand operand \((.*?)\n    \);', old_top, re.S).group(1)
    function = re.search(r'    function automatic logic protected_range_exceeded\(.*?endfunction', top, re.S).group(0)
    proof = '''module miter(
input [15:0] protected_msw, address_offset, vector_offset, stack_offset, operand_offset,
input [63:0] protected_segment_limits, real_segment_limits,
input [31:0] protected_segment_access, real_segment_access_state,
input [1:0] selected_segment_index,
input operand_byte, protected_event_access, protected_descriptor_access,
input protected_tss_access, protected_call_stack_access,
input vector_request, io_transfer, address_override, stack_request,
output mismatch);
wire [15:0] service_offset, selected_segment_limit, segment_limit, offset, op_limit;
wire [7:0] selected_segment_access;
wire protected_segment_is_code, protected_segment_is_expand_down;
wire segment_expand_down, request_byte, within_limit;
'''+function+'\n'
    for name in ('service_offset', 'selected_segment_limit', 'selected_segment_access',
                 'segment_limit', 'protected_segment_is_code', 'protected_segment_is_expand_down'):
        proof += assignment(old_top, name)+'\n'
    for name in ('offset', 'segment_expand_down', 'request_byte'):
        proof += 'assign '+name+'='+port(binding, name)+';\n'
    proof += 'assign op_limit='+port(binding, 'segment_limit')+';\n'
    proof += old_assignment.replace('segment_limit', 'op_limit')+'\n'+helper
    proof += '\nassign mismatch=within_limit!=parallel_operand_within_limit;\nendmodule\n'

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
    assert result.returncode == 0 and 'SUCCESS!' in result.stdout, 'Cache range equivalence failed'
    negative = proof.replace('io_transfer ? operand_io_ranges[selected_segment_index]',
                             "1'b0 ? operand_io_ranges[selected_segment_index]")
    assert negative != proof
    result = run(negative, 'negative', False)
    assert result.returncode == 0 and 'FAIL!' in result.stdout, 'I/O priority mutant not rejected'
    (out/'receipt.json').write_text(json.dumps({
        'status': 'EXACT_GENERIC_OPERAND_CACHE_RANGE_EQUIVALENCE_PASS',
        'reference': REFERENCE,
        'scope': 'all two-state offsets, all four real/protected hidden cache limits/access bytes, arbitrary selector, mode, width and overlapping I/O/vector/stack/address/special service flags; actual old operand binding; all other top and operand sequential/output RTL unchanged; default/baseline parameter retains the original range expression',
        'negative_control': 'IO_PRIORITY_MUTANT_REJECTED',
        'source_sha256': {p: hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths},
        'evidence_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in out.iterdir() if p.is_file()}
    }, indent=2)+'\n')
    print('OPERAND_CACHE_RANGE_FORMAL_PASS; I/O priority mutant rejected')


if __name__ == '__main__':
    main()
