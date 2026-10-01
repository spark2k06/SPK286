#!/usr/bin/env python3
"""Prove source classification against the unchanged actual vector priority."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

REFERENCE = 'fd9cd4c'


def assignment(text, name):
    return re.search(r'    assign ' + name + r'\s*=.*?;', text, re.S).group(0)


def compact(text):
    return re.sub(r'\s+', '', re.sub(r'//[^\n]*|/\*.*?\*/', '', text, flags=re.S))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('output', type=Path)
    out = ap.parse_args().output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    path = root / 'rtl/spk286.sv'
    source = path.read_text()
    old = subprocess.check_output(['git', 'show', REFERENCE + ':rtl/spk286.sv'], cwd=root, text=True)
    if compact(assignment(source, 'fault_vector')) != compact(assignment(old, 'fault_vector')):
        raise ValueError('Fault vector priority changed')
    helpers = [assignment(source, n) for n in ('loadall_fault_has_error', 'system_fault_has_error')]
    restored = source.replace('logic loadall_fault_has_error, system_fault_has_error;', '')
    for helper in helpers: restored = restored.replace(helper, '')
    restored = restored.replace(assignment(source, 'fault_error_valid'), assignment(old, 'fault_error_valid'))
    if compact(restored) != compact(old):
        raise ValueError('CPU changed outside source classification')
    inputs = ['input ' + n for n in ('invalid_form', 'invalid_opcode_fault', 'loadall_fault', 'system_fault',
              'protected_access_ss_fault', 'system_limit_fault', 'range_fault', 'protected_access_fault',
              'protected_fetch_fault', 'bounds_fault', 'arithmetic_fault')]
    inputs += ['input [7:0] loadall_fault_vector, system_fault_vector',
               'input [15:0] protected_msw', 'input [1:0] service_segment']
    text = 'module miter(\n' + ',\n'.join(inputs) + ',\noutput mismatch);\n'
    text += 'wire [7:0] fault_vector; wire old_valid, fault_error_valid;\n'
    text += 'wire loadall_fault_has_error, system_fault_has_error;\n'
    text += assignment(old, 'fault_vector') + '\n'
    text += assignment(old, 'fault_error_valid').replace('assign fault_error_valid', 'assign old_valid') + '\n'
    text += '\n'.join(helpers) + '\n' + assignment(source, 'fault_error_valid') + '\n'
    text += 'assign mismatch = old_valid != fault_error_valid;\nendmodule\n'
    miter = out / 'miter.sv'; miter.write_text(text)
    def run(p, log, verify):
        command = f'read_verilog -sv {p}; prep -top miter; flatten; opt; sat ' + ('-verify ' if verify else '') + '-prove mismatch 0 -show-inputs'
        result = subprocess.run(['yosys', '-p', command], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write_text(result.stdout)
        return result
    proof = out / 'proof.log'
    result = run(miter, proof, True)
    if result.returncode or 'SUCCESS!' not in result.stdout: raise RuntimeError('Proof failed: ' + str(proof))
    mutant = out / 'mutant.sv'
    mutant.write_text(text.replace('!(invalid_form || invalid_opcode_fault)', '!invalid_form', 1))
    negative = out / 'negative.log'
    result = run(mutant, negative, False)
    if result.returncode or 'FAIL!' not in result.stdout: raise RuntimeError('Priority mutant was not rejected')
    receipt = {'schema': 1, 'status': 'EXACT_FAULT_ERROR_VALID_EQUIVALENCE_PASS', 'reference': REFERENCE,
        'scope': 'all two-state source flags, all 256 values of each vector, protected state and segment; simultaneous faults included; no vector priority or sequential change',
        'negative_control': 'REJECTED', 'source_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'evidence_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (miter, proof, mutant, negative)}}
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('FAULT_ERROR_CLASSIFICATION_FORMAL_PASS; simultaneous priorities exact; mutant rejected')


if __name__ == '__main__':
    main()
