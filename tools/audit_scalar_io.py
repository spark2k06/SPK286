"""Require valid, isolated port expectation mutations to fail the comparator."""
import argparse
from dataclasses import replace
from pathlib import Path
import subprocess
from tools.singlestep import load_source
from tools.run_singlestep import prepare_case,write_batch

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--repo',type=Path,required=True);parser.add_argument('--build-dir',type=Path,default=Path('build'))
    args=parser.parse_args();output=args.build_dir/'scalar-io-audit';output.mkdir(parents=True,exist_ok=True)
    cases=load_source(args.repo/'v1_real_mode/EF.MOO.gz')
    prepared=next(prepare_case(c,'EF',True,True) for c in cases if c.exception is None and not c.initial['regs']['dx']%2)
    assert len(prepared.expected_io)==1
    cycle=prepared.expected_io[0]
    variants={'pristine':prepared,
              'duplicate':replace(prepared,expected_io=prepared.expected_io*2),
              'missing':replace(prepared,expected_io=()),
              'address':replace(prepared,expected_io=((cycle[0],cycle[1]^2,cycle[2],cycle[3]),)),
              'direction':replace(prepared,expected_io=((1-cycle[0],*cycle[1:]),)),
              'lane':replace(prepared,expected_io=((cycle[0],cycle[1],1,cycle[3]&255),)),
              'data':replace(prepared,expected_io=((cycle[0],cycle[1],cycle[2],cycle[3]^1),))}
    executable=(args.build_dir/'verilator/obj_dir/spk286_smoke').resolve()
    for name,case in variants.items():
        batch=output/(name+'.bin');write_batch(batch,[case])
        run=subprocess.run([str(executable),'--singlestep-batch',str(batch.resolve())],capture_output=True,text=True,timeout=30)
        (output/(name+'.log')).write_text(run.stdout+run.stderr)
        if name=='pristine':assert run.returncode==0 and 'passed=1 failed=0' in run.stdout
        else:assert run.returncode==1 and 'I/O transaction mismatch' in run.stdout and 'passed=0 failed=1' in run.stdout
        print(f'IO_COMPARATOR {name}: status={run.returncode}')
    print('IO_COMPARATOR PASS: pristine plus six intended port comparison failures')
if __name__=='__main__':main()
