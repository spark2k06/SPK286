"""Build portable images and explicit NOT-RUN capture records with NASM."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MARKERS = {name: address for name, address in (
    ('boot', 0x2000), ('armed', 0x2002), ('following', 0x2010),
    ('gp', 0x2020), ('restored_tf', 0x2022), ('db', 0x2030),
    ('nmi_first', 0x2040), ('nmi_terminal', 0x2042),
    ('intr', 0x2050), ('ud', 0x2060), ('iret_success', 0x2070),
    ('dump_completed', 0x2080), ('unexpected', 0x20f0))}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def cases():
    result = []
    for sp in (0xffff, 0xfffd, 0xfffb, 0x9000):
        for edge in ('second-edge', 'no-second', 'held-high'):
            result.append(dict(id=f'A-{sp:04x}-{edge}', family='A',
                               defines=dict(FAMILY=1, IRET_SP=sp), stimulus=edge))
    for flags, repeated in ((2, 0), (0x202, 0), (2, 1)):
        result.append(dict(id=f'B-if{int(bool(flags & 0x200))}-sti{repeated+1}', family='B',
                           defines=dict(FAMILY=2, FLAGS_IMAGE=flags, REPEATED_STI=repeated),
                           stimulus='intr-after-tested-opcode'))
    for kind, flags, offset, ud, restore in (
        ('gp-tf1', 0x102, 0xffff, 0, 0), ('gp-tf0', 2, 0xffff, 0, 0),
        ('success-tf1', 0x102, 0xfffe, 0, 0), ('ud-tf1', 0x102, 0xffff, 1, 0),
        ('gp-restore-tf', 0x102, 0xffff, 0, 1)):
        for nmi in (False, True) if kind == 'gp-tf1' else (False,):
            result.append(dict(id=f'C-{kind}' + ('-nmi' if nmi else ''), family='C',
                               defines=dict(FAMILY=3, FLAGS_IMAGE=flags, TARGET_OFFSET=offset,
                                            UD_TARGET=ud, RESTORE_TF=restore),
                               stimulus='nmi-during-target' if nmi else 'none'))
    return result


def make_memory(code, case):
    # Full regions make every read explicit; all other physical bytes are 0xCC.
    low = bytearray(0x10000)
    for vector in range(256):
        handler = {1: 0x500, 2: 0x600, 6: 0x800, 13: 0x400, 0x40: 0x700}.get(vector, 0xa00)
        low[vector*4:vector*4+4] = handler.to_bytes(2, 'little') + b'\x00\x10'
    stack = bytearray([0xa5]) * 0x10000
    sp = case['defines'].get('IRET_SP', 0x9000)
    # Failing attempts have 0/1/2 valid reads; descending exception frames fit.
    for index, value in enumerate((0x900, 0x1000, 2)):
        offset = sp + 2*index
        if offset < 0xffff:
            stack[offset:offset+2] = value.to_bytes(2, 'little')
    reset = bytes.fromhex('ea00010010') + bytes([0xcc])*11
    return [(0, bytes(low), 'low.bin'), (0x10000, code, 'code.bin'),
            (0x30000, bytes(stack), 'stack.bin'), (0xfffff0, reset, 'reset.bin')]


def verify_encoding(code, case):
    assert len(code) == 0x1000 and code[0x100] == 0xfa
    assert code[0x640] == 0xcf
    for offset, address in ((0x400, 0x2020), (0x500, 0x2030), (0x680, 0x2042),
                            (0x700, 0x2050), (0x800, 0x2060), (0x900, 0x2070)):
        assert code[offset:offset+4] == b'\x89\x16' + address.to_bytes(2, 'little')
    d = case['defines']
    if case['family'] == 'B':
        count = 1+d['REPEATED_STI']
        assert code[0x200:0x200+count] == b'\xfb'*count
        assert code[0x200+count:0x204+count] == bytes.fromhex('89161020')
    if case['family'] == 'C':
        assert code[0x1fc:0x200] == b'\x68' + d['FLAGS_IMAGE'].to_bytes(2, 'little') + b'\x9d'
        expected = bytes.fromhex('8fc8') if d['UD_TARGET'] else b'\x89\x06'+d['TARGET_OFFSET'].to_bytes(2, 'little')
        assert code[0x200:0x200+len(expected)] == expected


def build(output):
    output.mkdir(parents=True, exist_ok=False)
    version = subprocess.check_output(['nasm', '-v'], text=True).strip()
    manifest = dict(schema=1, provenance='not-run', assembler=version,
                    source_sha256=digest((HERE/'probes.asm').read_bytes()), cases=[])
    for case in cases():
        directory = output/case['id']
        directory.mkdir()
        command = ['nasm', '-f', 'bin', '-Wall', '-Werror', str(HERE/'probes.asm'),
                   '-o', str(directory/'code.bin'), '-l', str(directory/'code.lst')]
        command += [f'-D{k}={v}' for k, v in sorted(case['defines'].items())]
        subprocess.run(command, check=True)
        code = (directory/'code.bin').read_bytes()
        verify_encoding(code, case)
        disassembly = subprocess.check_output(['ndisasm', '-b', '16', str(directory/'code.bin')])
        (directory/'disassembly.txt').write_bytes(disassembly)
        regions = []
        for address, data, name in make_memory(code, case):
            (directory/name).write_bytes(data)
            regions.append(dict(address=address, size=len(data), file=name, sha256=digest(data)))
        config = {**case, 'schema': 1, 'mode': 'real', 'start': 'physical-reset',
                  'memory_default': 0xcc, 'regions': regions, 'markers': MARKERS,
                  'target_cs': 0x1000, 'target_ip': 0x640 if case['family']=='A' else 0x200,
                  'stack_segment': 0x3000, 'intr_vector': 0x40,
                  'capture_stop': 'passive bus/memory capture after terminal HLT; no injected NMI',
                  'fixture_integration': 'required; portable payload only'}
        (directory/'config.json').write_text(json.dumps(config, indent=2)+'\n')
        record = dict(schema=1, id=case['id']+'-capture-001', test_id=case['id'],
                      provenance='not-run', status='not-run', source=None, cpu=None, fixture=None,
                      initial=None, stimulus=None, observation=None, controls=[], raw_artifacts=[])
        (directory/'result.not-run.json').write_text(json.dumps(record, indent=2)+'\n')
        manifest['cases'].append({**case, 'config_sha256': digest((directory/'config.json').read_bytes()),
                                  'files': {p.name: digest(p.read_bytes()) for p in sorted(directory.iterdir())}})
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True)+'\n')
    print(f'PROBE_BUILD PASS: {len(manifest["cases"])} payload configurations; physical executions=0')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build(args.output)


if __name__ == '__main__':
    main()
