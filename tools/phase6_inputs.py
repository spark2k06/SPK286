"""Fingerprint executable validation inputs, independently of build products."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]


def snapshot():
    names=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=ROOT).decode().split('\0')
    roots={'rtl','sim','tools','scripts','tests','microcode','research','.github'}
    selected=sorted({name for name in names if name and
                     (name.split('/')[0] in roots or name in ('Makefile','AGENTS.md','.gitattributes','docs/phase6_evidence.json'))})
    return {name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in selected}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest',type=Path,required=True)
    parser.add_argument('--check',action='store_true')
    args=parser.parse_args()
    current=snapshot()
    if args.check:
        if json.loads(args.manifest.read_text())!=current:
            raise SystemExit('PHASE6_INPUTS ERROR: validation inputs changed during the run')
    else:
        args.manifest.write_text(json.dumps(current,indent=2,sort_keys=True)+'\n')
    print(f'PHASE6_INPUTS PASS: {len(current)} executable validation inputs fingerprinted')


if __name__=='__main__':main()
