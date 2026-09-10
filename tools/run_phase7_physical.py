"""Run every required physical file; retain preparation errors and fail overall."""
import argparse
from collections import Counter
import contextlib
import hashlib
import json
from pathlib import Path
import time
from tools.phase7_scope import require_complete
from tools.run_singlestep import SUPPORTED_OPCODES, run_opcode, SingleStepRunnerError
from tools.singlestep import load_revocation_list


def run_all(opcodes,execute):
    records=[];totals=Counter();errors=[]
    keys=('discovered','revoked','prefix_skipped','exception_skipped','selection_skipped','executed','passed','failed')
    for opcode in opcodes:
        started=time.time()
        try:
            values=execute(opcode)
            if len(values)!=8 or any(type(v) is not int or v<0 for v in values):raise ValueError('malformed physical result counters')
            counts=dict(zip(keys,values));totals.update(counts)
            record=dict(opcode=opcode,counts=counts)
            if counts['failed'] or any(counts[k] for k in ('prefix_skipped','exception_skipped','selection_skipped')):
                errors.append(dict(opcode=opcode,error='required execution failed or was excluded'))
        except (SingleStepRunnerError,OSError,ValueError) as error:
            record=dict(opcode=opcode,error=str(error));errors.append(dict(record))
        record.update(start=started,end=time.time());records.append(record)
    return dict(validation='FAIL' if errors else 'PASS',totals=dict(totals),errors=errors,records=records)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo',type=Path,required=True)
    parser.add_argument('--executable',type=Path,required=True)
    parser.add_argument('--build-dir',type=Path,required=True)
    args=parser.parse_args();require_complete()
    if args.build_dir.exists():raise ValueError('choose a previously absent physical output directory')
    if not args.executable.is_file():raise ValueError('missing simulator executable')
    args.build_dir.mkdir(parents=True);logs=args.build_dir/'family-logs';logs.mkdir()
    revoked=load_revocation_list(args.repo/'revocation_list.txt')
    args.include_exceptions=True;args.include_prefixes=True;args.full=True
    args.sample=None;args.index=None;args.test_hash=None;args.trace=None
    def execute(opcode):
        with (logs/(opcode+'.log')).open('w') as log,contextlib.redirect_stdout(log),contextlib.redirect_stderr(log):
            return run_opcode(opcode,args.repo,revoked,args,args.build_dir,args.executable.resolve())
    summary=run_all(SUPPORTED_OPCODES,execute)
    from tools.phase7_capture_admission import CAPTURE, validate_dispositions
    from tools.phase6_reports import unique_object
    summary['required_files']=307;summary['required_population']=1386997;summary['required_executed']=1386996
    dispositions=[]
    for record in summary['records']:
        if 'error' not in record:
            report=json.loads((args.build_dir/'singlestep/reports'/(record['opcode']+'.json')).read_text(),object_pairs_hook=unique_object)
            validate_dispositions(report.get('not_evaluable',[]),record['opcode'])
            dispositions.extend(report.get('not_evaluable',[]))
    summary['not_evaluable']=dispositions
    summary['executable_sha256']=hashlib.sha256(args.executable.read_bytes()).hexdigest()
    if len(summary['records'])!=307 or dispositions!=[CAPTURE] or summary['totals'].get('executed')!=1386996 or summary['totals'].get('passed')!=1386996:
        summary['validation']='FAIL'
        summary['errors'].append({'error':'incomplete required physical execution'})
    (args.build_dir/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('PHASE7_PHYSICAL '+summary['validation']+': '+json.dumps(summary['totals'])+'; errors='+str(len(summary['errors'])))
    for error in summary['errors']:print(json.dumps(error))
    return 0 if summary['validation']=='PASS' else 1


if __name__=='__main__':raise SystemExit(main())
