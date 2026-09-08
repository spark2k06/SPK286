"""Fail-closed accounting for a complete, unrevoked Phase 6 hardware run."""
import argparse
import json
from pathlib import Path
from tools.phase6_cohort import SUPPORTED_OPCODES, INHERITED_OPCODES, PHASE6_OPCODES


def require(value, message):
    if not value: raise ValueError(message)


def unique_object(pairs):
    result={}
    for name,value in pairs:
        require(name not in result,f'duplicate JSON field {name}')
        result[name]=value
    return result


def validate_report(opcode, report):
    require(isinstance(report,dict) and report.get('opcode')==opcode,f'{opcode}: wrong report identity')
    counters=('discovered','revoked','prefix_skipped','exception_skipped','selection_skipped','selected',
              'executed','passed','failed','inherited_selected','fault_selected','phase6_selected')
    for field in counters:
        require(type(report.get(field)) is int and report[field]>=0,f'{opcode}: invalid/missing counter {field}')
    r=report
    require(r['discovered']==(1000 if opcode in ('F4','FA','FB') else 5000),f'{opcode}: incomplete source discovery')
    require(r['revoked']==r['exception_skipped']==r['selection_skipped']==r['failed']==0,f'{opcode}: excluded/failed mandatory cases')
    require(r['selected']==r['executed']==r['passed']>0,f'{opcode}: incomplete execution')
    require(r['discovered']==r['prefix_skipped']+r['executed'],f'{opcode}: discovery accounting mismatch')
    require(r['inherited_selected']+r['fault_selected']+r['phase6_selected']==r['executed'],f'{opcode}: category accounting mismatch')
    require((r['phase6_selected']==0 if opcode in INHERITED_OPCODES else r['inherited_selected']==r['fault_selected']==0),f'{opcode}: wrong category')
    exclusions=r.get('exclusions')
    require(isinstance(exclusions,list) and len(exclusions)==r['prefix_skipped'],f'{opcode}: exclusion identities missing')
    indexes=set()
    for entry in exclusions:
        require(isinstance(entry,dict) and entry.get('reason')=='unsupported_prefix',f'{opcode}: unapproved exclusion reason')
        require(type(entry.get('index')) is int and entry['index']>=0 and entry['index'] not in indexes,f'{opcode}: duplicate/invalid exclusion identity')
        require(isinstance(entry.get('hash'),str) and len(entry['hash'])==40,f'{opcode}: missing exclusion hash')
        indexes.add(entry['index'])
    return r


def summarize(directory):
    require(directory.is_dir(),'missing hardware report directory')
    require({p.stem for p in directory.glob('*.json')}==set(SUPPORTED_OPCODES),'missing/extra hardware opcode reports')
    reports=[]
    for opcode in SUPPORTED_OPCODES:
        report=json.loads((directory/(opcode+'.json')).read_text(),object_pairs_hook=unique_object)
        reports.append(validate_report(opcode,report))
    totals={key:sum(r[key] for r in reports) for key in
            ('discovered','prefix_skipped','executed','passed','failed','inherited_selected','fault_selected','phase6_selected')}
    expected={'discovered':518000,'prefix_skipped':43951,'executed':474049,'passed':474049,'failed':0,
              'inherited_selected':440574,'fault_selected':1423,'phase6_selected':32052}
    require(totals==expected,f'Phase 6 complete-corpus totals differ: {totals}')
    return {'validation':'PASS','corpus_revision':'37c73caf53dcd22d3dd369ff09305d13d117a4fe',
            'totals':totals,'opcodes':reports}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reports',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    summary=summarize(args.reports)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(summary,indent=2,sort_keys=True)+'\n')
    print('PHASE6_CORPUS PASS: 440574 inherited + 1423 formerly excluded faults + 32052 new = 474049')


if __name__=='__main__':
    try: main()
    except (ValueError,OSError) as error:
        raise SystemExit(f'PHASE6_CORPUS ERROR: {error}')
