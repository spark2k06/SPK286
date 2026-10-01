#!/usr/bin/env python3
"""Prove the actual descriptor/gate word-3 predicate factoring."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

REFERENCE = 'fd9cd4c'


def compact(text):
    return re.sub(r'\s+', '', re.sub(r'//[^\n]*|/\*.*?\*/', '', text, flags=re.S))


def assignment(text, name):
    return re.search(r'    assign ' + name + r'\s*=.*?;', text, re.S).group(0)


def block(text, prefix, first):
    start = text.index('    assign ' + prefix + first)
    end = text.index('\n    );', start) + len('\n    );')
    return text[start:end]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('output', type=Path)
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = (root / 'rtl/spk286_micro_executor.sv').read_text()
    old = subprocess.check_output(['git', 'show', REFERENCE + ':rtl/spk286_micro_executor.sv'], cwd=root, text=True)
    descriptor_path = root / 'rtl/spk286_descriptor.sv'
    descriptor = descriptor_path.read_text()
    old_descriptor = subprocess.check_output(['git', 'show', REFERENCE + ':rtl/spk286_descriptor.sv'], cwd=root, text=True)
    if compact(descriptor) != compact(old_descriptor):
        raise ValueError('Descriptor parser changed outside this proof')
    ports = re.findall(r'output\s+logic\s*(\[[^\]]+\])?\s*(\w+)\s*[,\n]', descriptor.split(');', 1)[0])
    assert len(ports) == 18, ports
    restored = source
    receipts = {}
    for prefix, instance in (('descriptor', 'descriptor_parser'), ('event_gate', 'event_gate_parser')):
        new_block = block(source, prefix, '_high_word_valid')
        old_block = block(old, prefix, '_raw_q')
        restored = restored.replace(new_block, old_block).replace(
            f'logic {prefix}_low_valid, {prefix}_low_reserved_valid, {prefix}_high_word_valid;',
            f'logic [63:0] {prefix}_raw_q, {prefix}_raw_candidate;')
        bindings = dict(re.findall(r'\.(\w+)\(([^()]*)\)', new_block))
        assert bindings['raw_descriptor'] == "{16'h0000, " + ', '.join(prefix + f'_word{i}_q' for i in (2,1,0)) + '}'
        assert all(re.fullmatch(r'\w+', bindings[p]) for _,p in ports)
        declaration = ',\n    '.join('input [15:0] ' + prefix + f'_word{i}_q' for i in range(4))
        text = ('module miter(\n    ' + declaration + ',\n    input [15:0] operand_read_data,\n'
                + '    input ' + prefix + '_operand_done,\n    input [2:0] ' + prefix + '_phase_q,\n'
                + '    output mismatch\n);\n')
        for width, port in ports:
            text += f'wire {width} old_{port}, {bindings[port]};\n'
        text += f'wire [63:0] {prefix}_raw_q, {prefix}_raw_candidate;\n'
        text += f'wire {prefix}_high_word_valid, {prefix}_valid, {prefix}_reserved_valid;\n'
        for name in ('_raw_q', '_raw_candidate'):
            text += assignment(old, prefix + name) + '\n'
        for name in ('_high_word_valid', '_valid', '_reserved_valid'):
            text += assignment(source, prefix + name) + '\n'
        for name, raw, values in (
                ('reference_parser', prefix + '_raw_candidate', {p:'old_' + p for _,p in ports}),
                ('candidate_parser', bindings['raw_descriptor'], bindings)):
            text += 'spk286_descriptor ' + name + '(.raw_descriptor(' + raw + '),\n'
            text += ',\n'.join('.' + p + '(' + values[p] + ')' for _,p in ports) + ');\n'
        corrected = dict(bindings)
        corrected['descriptor_valid'] = prefix + '_valid'
        corrected['reserved_form_valid'] = prefix + '_reserved_valid'
        text += 'assign mismatch = ' + ' ||\n'.join('old_' + p + ' != ' + corrected[p] for _,p in ports) + ';\nendmodule\n'
        miter = output / (prefix + '.sv')
        miter.write_text(text)
        def run(path, log, verify):
            command = (f'read_verilog -sv {descriptor_path} {path}; hierarchy -top miter; '
                       'prep -top miter; flatten; opt; sat ' + ('-verify ' if verify else '')
                       + '-prove mismatch 0 -show-inputs')
            result = subprocess.run(['yosys', '-p', command], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            log.write_text(result.stdout)
            return result
        log = output / (prefix + '-proof.log')
        result = run(miter, log, True)
        if result.returncode or 'SUCCESS!' not in result.stdout:
            raise RuntimeError('Exact parser-output proof failed: ' + str(log))
        mutant = output / (prefix + '-mutant.sv')
        assert '(operand_read_data == 16\'h0000)' in text
        mutant.write_text(text.replace("(operand_read_data == 16'h0000)", "(operand_read_data == 16'h0001)", 1))
        negative = output / (prefix + '-negative.log')
        result = run(mutant, negative, False)
        if result.returncode or 'FAIL!' not in result.stdout:
            raise RuntimeError('Mutant was not rejected: ' + str(negative))
        receipts[prefix] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (miter, log, mutant, negative)}
    if compact(restored) != compact(old):
        raise ValueError('Executor changed outside the proven parser fragments')
    receipt = {'schema': 1, 'status': 'EXACT_ALL_PARSER_OUTPUTS_EQUIVALENCE_PASS',
               'reference': REFERENCE, 'outputs_per_service': len(ports),
               'scope': 'all two-state descriptor words, operand data, completion and phase; both services; no sequential changes',
               'negative_controls': 'both rejected', 'source_sha256': {
                   'rtl/spk286_micro_executor.sv': hashlib.sha256((root / 'rtl/spk286_micro_executor.sv').read_bytes()).hexdigest(),
                   'rtl/spk286_descriptor.sv': hashlib.sha256(descriptor_path.read_bytes()).hexdigest()},
               'evidence_sha256': receipts}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('DESCRIPTOR_WORD_SELECT_FORMAL_PASS all 18 outputs / both services; mutants rejected')


if __name__ == '__main__':
    main()
