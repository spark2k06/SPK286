"""CPU-only synthetic OUT imm8,AX reproduction; never hardware-derived evidence."""
import argparse
import json
from pathlib import Path
import subprocess
from tools.run_singlestep import PreparedCase, REG_ORDER, write_batch, RESULT_RE
from tools.phase6_reports import require
from tools.singlestep import SingleStepCase


def cases():
    # Independently specified word outputs, including the incomplete capture's
    # stated initial AX/IP. No physical payload or expectation is inferred.
    for port in (0,2,3,255):
        regs=dict.fromkeys(REG_ORDER,0)
        regs.update(ax=0xF6CA,ip=0x3848,flags=0x0002,sp=0x2000)
        initial=tuple(regs[n] for n in REG_ORDER)
        expected=dict(regs,ip=0x384A)  # Retirement ends OUT, before trailing HLT.
        ram=tuple((0x3848+i,b) for i,b in enumerate((0xE7,port,0xF4)))
        transactions=((1,port,0,0xF6CA),) if port%2==0 else ((1,port,0,0xCA00),(1,port+1,1,0x00F6))
        yield initial,tuple(expected[n] for n in REG_ORDER),ram,transactions


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable',type=Path,required=True)
    parser.add_argument('--build-dir',type=Path,required=True)
    args=parser.parse_args();args.build_dir.mkdir(parents=True,exist_ok=False)
    prepared=[]
    for index,(initial,expected,ram,transactions) in enumerate(cases()):
        source=SingleStepCase(index,'SYNTHETIC word OUT port '+str(ram[1][1]),
                              (0xE7,ram[1][1],0xF4),{}, {},None,None,(),{})
        prepared.append(PreparedCase(source=source,initial_regs=initial,expected_regs=expected,
            expected_masks=(0xffff,)*len(REG_ORDER),initial_ram=ram,expected_ram=ram,
            expected_io=transactions))
    batch=args.build_dir/'synthetic-out.bin';write_batch(batch,prepared)
    result=subprocess.run([str(args.executable.resolve()),'--singlestep-batch',str(batch.resolve())],capture_output=True,text=True,timeout=60)
    (args.build_dir/'synthetic-out.log').write_text(result.stdout+result.stderr)
    require(result.returncode==0 and RESULT_RE.findall(result.stdout)==[(str(len(prepared)),str(len(prepared)),'0')],
            'synthetic OUT reproduction failed: '+result.stdout+result.stderr)
    report=dict(validation='PASS',provenance='synthetic independently specified CPU tests',executed=len(prepared),passed=len(prepared),physical_captures=0)
    (args.build_dir/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
    print('SYNTHETIC_OUT PASS: four independent immediate word-output cases; zero physical observations')


if __name__=='__main__':main()
