# SPDX-License-Identifier: MIT
"""Assemble CPU-only late-task reset ROMs and their simulator manifest."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def generate(out):
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).resolve().parents[1]/'sim/programs/task_late_fault.asm'
    cases = []
    for entry in range(4):
        for stage in range(8):
            for absent in ([0,1] if 2 <= stage <= 5 else [0]):
                for handler in ([1] if stage in (1,2,7) else [0,1]):
                    name = f's{stage}-e{entry}-a{absent}-h{handler}'
                    rom, hexf = out/(name+'.rom'), out/(name+'.hex')
                    subprocess.run(['nasm','-f','bin',f'-DFAULT_STAGE={stage}',
                        f'-DENTRY={entry}',f'-DABSENT={absent}',f'-DTASK_HANDLER={handler}',
                        str(source),'-o',str(rom)],check=True)
                    data = rom.read_bytes()
                    assert len(data) == 65536
                    hexf.write_text('\n'.join(f'{b:02x}' for b in data)+'\n')
                    cases.append(dict(name=name,stage=stage,entry=entry,absent=absent,
                                      handler=handler,rom=str(rom),hex=str(hexf),
                                      sha256=hashlib.sha256(data).hexdigest()))
    (out/'vectors.txt').write_text(''.join(f"{c['hex']} {c['stage']} {c['entry']} {c['absent']} {c['handler']}\n" for c in cases))
    (out/'manifest.json').write_text(json.dumps({'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'cases':cases},indent=2)+'\n')
    print(f'TASK_LATE_VECTORS {len(cases)} cases: {out}')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,required=True)
    generate(p.parse_args().output)
