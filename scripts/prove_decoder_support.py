#!/usr/bin/env python3
"""Prove the dense decoder-map complement and preserve all other metadata."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

REFERENCE = '3a480ae'


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
    path = root / 'rtl/spk286_decoder.sv'
    source = path.read_text()
    old = subprocess.check_output(['git', 'show', REFERENCE + ':rtl/spk286_decoder.sv'], cwd=root, text=True)
    expected = old.replace(assignment(old, 'supported'), assignment(source, 'supported'))
    expected = expected.replace('    logic string_instruction;', '').replace('stack_control, event_instruction, ', '')
    for name in ('string_instruction', 'event_instruction', 'stack_control'):
        expected = expected.replace(assignment(old, name), '')
    if compact(expected) != compact(source):
        raise ValueError('Decoder changed outside support expression/unused helper removal')
    names = ('scalar_io', 'string_io', 'string_instruction', 'binary_byte', 'binary_word',
             'stack_control', 'event_instruction', 'test_instruction', 'adjust_instruction',
             'segment_instruction', 'esc_instruction')
    text = 'module miter(input [7:0] opcode, input extended_opcode, output mismatch);\n'
    text += 'wire ' + ', '.join(names) + ', old_supported, new_supported;\n'
    text += '\n'.join(assignment(old, n) for n in names) + '\n'
    text += assignment(old, 'supported').replace('assign supported', 'assign old_supported') + '\n'
    text += assignment(source, 'supported').replace('assign supported', 'assign new_supported') + '\n'
    text += 'assign mismatch = old_supported != new_supported;\nendmodule\n'
    miter = out / 'miter.sv'; miter.write_text(text)
    def run(p, log, verify):
        command = f'read_verilog -sv {p}; prep -top miter; flatten; opt; sat ' + ('-verify ' if verify else '') + '-prove mismatch 0 -show-inputs'
        result = subprocess.run(['yosys', '-p', command], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write_text(result.stdout)
        return result
    proof = out / 'proof.log'
    result = run(miter, proof, True)
    if result.returncode or 'SUCCESS!' not in result.stdout: raise RuntimeError('Proof failed: ' + str(proof))
    mutant = out / 'mutant.sv'; mutant.write_text(text.replace("opcode == 8'h82 || ", '', 1))
    negative = out / 'negative.log'
    result = run(mutant, negative, False)
    if result.returncode or 'FAIL!' not in result.stdout: raise RuntimeError('Decoder mutant was not rejected')
    # Preserve the full reference module for independent exhaustive metadata
    # comparison in both executable simulators, not just the Boolean miter.
    reference = out / 'reference.sv'
    reference.write_text(old.replace('module spk286_decoder (', 'module spk286_decoder_reference (', 1))
    receipt = {'schema': 1, 'status': 'EXACT_DECODER_SUPPORT_EQUIVALENCE_PASS',
               'reference': REFERENCE, 'scope': 'all 512 two-state opcode/map pairs; surrounding decoder metadata unchanged',
               'negative_control': 'REJECTED', 'source_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
               'evidence_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (miter,proof,mutant,negative,reference)}}
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('DECODER_SUPPORT_FORMAL_PASS all 512 combinations; mutant rejected')


if __name__ == '__main__':
    main()
