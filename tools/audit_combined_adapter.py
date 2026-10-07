"""Exercise both batch extensions together on the actual CPU comparator."""
import argparse
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import struct
import subprocess
from tools.run_singlestep import prepare_case, write_batch, RESULT_RE
from tools.singlestep import load_source


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo',type=Path,required=True)
    parser.add_argument('--executable',type=Path,required=True)
    parser.add_argument('--build-dir',type=Path,required=True)
    args=parser.parse_args();args.build_dir.mkdir(parents=True,exist_ok=True)
    sources={};records=[]
    def select(opcode,predicate):
        path=args.repo/'v1_real_mode'/(opcode+'.MOO.gz')
        sources[path]=hashlib.sha256(path.read_bytes()).hexdigest()
        case=next(c for c in load_source(path) if predicate(c))
        records.append(dict(opcode=opcode,index=case.index,hash=case.test_hash))
        return prepare_case(case,opcode,True,True)
    output=select('EF',lambda c:c.exception is None and c.initial['regs']['dx']%2==0)
    incoming=select('ED',lambda c:c.exception is None and c.initial['regs']['dx']%2==0)
    divides=[select(op,lambda c:c.exception and c.exception['number']==0) for op in ('F6.6','F6.7','F7.6','F7.7')]
    positive=[output,incoming]+divides;negative=[]
    for case in divides:
        address=case.source.exception['flag_address'];expected=dict(case.expected_ram);masks=dict(case.expected_ram_masks)
        for offset in range(-4,2):
            for bit in range(8):
                altered=dict(expected);altered[address+offset]^=1<<bit
                variant=replace(case,expected_ram=tuple(sorted(altered.items())))
                (negative if masks.get(address+offset,255)&(1<<bit) else positive).append(variant)
        changed=dict(expected);changed.pop(address-4)
        negative.append(replace(case,expected_ram=tuple(sorted(changed.items()))))
        extra=max(expected)+100;assert extra not in expected;changed[extra]=0
        negative.append(replace(case,expected_ram=tuple(sorted(changed.items()))))
    for case in (output,incoming):
        assert len(case.expected_io)==1
        direction,address,bhe,data=case.expected_io[0]
        for cycles in ((),case.expected_io*2,((direction,address^2,bhe,data),),
                       ((1-direction,address,bhe,data),),((direction,address,1,data&255),),
                       ((direction,address,bhe,data^1),)):
            negative.append(replace(case,expected_io=cycles))
    # Both batches contain a pristine mask-bearing fault and port cases. Even
    # variants with a missing port expectation must retain binary version 5.
    runs=[('positive',positive,len(positive),0),('negative-frame',positive[:6]+negative[:176],6,176),('negative-port',positive[:6]+negative[176:],6,12)]
    for name,cases,passed,failed in runs:
        batch=args.build_dir/(name+'.bin');write_batch(batch,cases)
        assert struct.unpack('<I',batch.read_bytes()[8:12])[0]==5
        result=subprocess.run([str(args.executable),'--singlestep-batch',str(batch.resolve())],capture_output=True,text=True,timeout=600)
        (args.build_dir/(name+'.log')).write_text(result.stdout+result.stderr)
        match=RESULT_RE.search(result.stdout)
        assert match and tuple(map(int,match.groups()))==(len(cases),passed,failed),(name,result.returncode,result.stdout[-3000:],result.stderr[-1000:])
        assert result.returncode==(1 if failed else 0)
        if name=='negative-port':assert 'I/O transaction mismatch' in result.stdout
        if name=='negative-frame':assert 'memory state mismatch' in result.stdout
    assert len(positive)==30 and len(negative)==188
    assert all(hashlib.sha256(path.read_bytes()).hexdigest()==value for path,value in sources.items())
    summary=dict(validation='PASS',batch_version=5,pristine_cases=6,declared_undefined_bit_variants=24,rejected_frame_address_or_port_mutants=188,records=records,source_sha256={str(p):v for p,v in sources.items()})
    (args.build_dir/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('COMBINED_ADAPTER_AUDIT PASS: 6 pristine; 24 undefined-bit variants; 188 rejected frame/address/port mutants; version 5; source unchanged')


if __name__=='__main__':main()
