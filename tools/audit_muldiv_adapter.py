# SPDX-License-Identifier: MIT
"""Prove the EXCP/RMSK boundary with genuine RTL executions and isolated mutations."""
import argparse
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import subprocess
from tools.run_singlestep import DIVIDE_OPCODES,RESULT_RE,prepare_case,write_batch
from tools.singlestep import load_source


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo',type=Path,required=True)
    parser.add_argument('--executable',type=Path,required=True)
    parser.add_argument('--build-dir',type=Path,required=True)
    args=parser.parse_args();args.build_dir.mkdir(parents=True,exist_ok=True)
    positive=[];negative=[];sources={};records=[]
    for opcode in DIVIDE_OPCODES:
        path=args.repo/'v1_real_mode'/(opcode+'.MOO.gz')
        sources[path]=hashlib.sha256(path.read_bytes()).hexdigest()
        case=next(c for c in load_source(path) if c.exception and c.exception['number']==0)
        prepared=prepare_case(case,opcode,True,True)
        positive.append(prepared)
        address=case.exception['flag_address']
        expected=dict(prepared.expected_ram);masks=dict(prepared.expected_ram_masks)
        assert masks[address]|masks[address+1]<<8==0xf72a
        # Every bit of the six-byte frame: exactly the six declared undefined
        # FLAGS bits may differ. CS, first-prefix IP and defined FLAGS must fail.
        for offset in range(-4,2):
            assert address+offset in expected
            for bit in range(8):
                changed=dict(expected);changed[address+offset]^=1<<bit
                mutant=replace(prepared,expected_ram=tuple(sorted(changed.items())))
                (positive if not (masks.get(address+offset,255)&(1<<bit)) else negative).append(mutant)
        # Different byte-address sets fail even when their cardinality agrees.
        changed=dict(expected);changed.pop(address-4)
        negative.append(replace(prepared,expected_ram=tuple(sorted(changed.items()))))
        extra=max(expected)+100;assert extra not in expected
        changed[extra]=0
        negative.append(replace(prepared,expected_ram=tuple(sorted(changed.items()))))
        records.append(dict(opcode=opcode,index=case.index,hash=case.test_hash,flag_address=address,mask=0xf72a))
    for name,cases,passed,failed in [('positive',positive,len(positive),0),('negative',negative,0,len(negative))]:
        batch=args.build_dir/(name+'.bin');write_batch(batch,cases)
        result=subprocess.run([str(args.executable),'--singlestep-batch',str(batch)],capture_output=True,text=True)
        (args.build_dir/(name+'.log')).write_text(result.stdout+result.stderr)
        match=RESULT_RE.search(result.stdout)
        assert match and tuple(map(int,match.groups()))==(len(cases),passed,failed),(name,result.returncode,result.stdout[-2000:],result.stderr[-1000:])
        assert result.returncode==(1 if failed else 0)
    assert len(positive)==28 and len(negative)==176
    assert all(hashlib.sha256(path.read_bytes()).hexdigest()==value for path,value in sources.items())
    summary=dict(validation='PASS',pristine_cases=4,declared_undefined_bit_variants=24,rejected_frame_or_address_mutants=176,records=records,source_sha256={str(path):value for path,value in sources.items()})
    (args.build_dir/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('MULDIV_ADAPTER_AUDIT PASS: 4 pristine cases; 24 declared undefined-bit variants; 176 rejected frame/address mutants; source bytes unchanged')


if __name__=='__main__':main()
