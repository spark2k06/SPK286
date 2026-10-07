"""Assemble null-LDTR field, readback and no-fetch reset programs."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def generate(output):
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).resolve().parents[1]/'sim/programs/task_late_fault.asm'
    cases = []
    # Scenario: 0 null task LDT; 1 illegal TI task LDT; 2/3 missing LDT
    # required by CS/SS; 4/5 valid LDT entry-zero CS/SS; 6/7 explicit LLDT.
    for entry in range(4):
        for scenario in range(6):
            selectors = range(4,8) if scenario == 1 else range(4) if scenario < 4 else [0x50]
            for selector in selectors:
                cases.append(dict(name=f'task-s{scenario}-e{entry}-l{selector:04x}',
                                  scenario=scenario, entry=entry, selector=selector))
    for selector in range(8):
        cases.append(dict(name=f'lldt-l{selector:04x}', scenario=6 if selector<4 else 7,
                          entry=0, selector=selector))
    for case in cases:
        scenario, selector = case['scenario'], case['selector']
        defines = dict(FAULT_STAGE=0, ENTRY=case['entry'], ABSENT=0,
                       TASK_HANDLER=int(scenario <= 3),
                       INCOMING_LDTR=selector if scenario < 6 else 0x50,
                       INCOMING_CS=4 if scenario in (2,4) else 0x30,
                       INCOMING_SS=4 if scenario in (3,5) else 0x38,
                       LDT_ZERO_CODE=int(scenario==4), LDT_ZERO_STACK=int(scenario==5))
        if scenario >= 6: defines['BOOT_LLDT'] = selector
        rom, hexf = output/(case['name']+'.rom'), output/(case['name']+'.hex')
        subprocess.run(['nasm','-f','bin',*[f'-D{k}={v}' for k,v in defines.items()],
                        str(source),'-o',str(rom)], check=True)
        data = rom.read_bytes()
        assert len(data)==65536
        hexf.write_text('\n'.join(f'{b:02x}' for b in data)+'\n')
        case.update(rom=str(rom), hex=str(hexf), sha256=hashlib.sha256(data).hexdigest())
    (output/'vectors.txt').write_text(''.join(f"{c['hex']} {c['scenario']} {c['entry']} {c['selector']}\n" for c in cases))
    (output/'manifest.json').write_text(json.dumps(dict(source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),cases=cases),indent=2)+'\n')
    print(f'NULL_LDTR_VECTORS {len(cases)} cases: {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    generate(parser.parse_args().output)
