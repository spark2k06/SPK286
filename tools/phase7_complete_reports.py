"""Strict all-family physical identities, pinned sources and original revocations."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
from tools.phase6_reports import require,unique_object
from tools.phase6_cohort import SUPPORTED_OPCODES as LEGACY
from tools.phase7_scope import require_complete
from tools.singlestep import load_source
from tools.phase7_capture_admission import CAPTURE, validate_dispositions, prepare_population

PINNED_REVOKED={'eaaf835a6600a351ee70375c7f6996931411bca5','1b586a46891182a22b3f55f71e4db4c601ac26e4','e64e6de35ca857a62a8f4ccc2bf991700a564b28'}


def validate_report(report,form,raw,revoked,seen):
    op=form['opcode'];discovered=form['case_count']
    dispositions=report.get('not_evaluable',[])
    validate_dispositions(dispositions,op)
    omitted={item['index'] for item in dispositions}
    count=discovered-len(revoked)-len(omitted)
    require(report.get('opcode')==op,'wrong opcode report')
    for key in ('discovered','revoked','prefix_skipped','exception_skipped','selection_skipped','selected','executed','passed','failed'):
        require(type(report.get(key)) is int and report[key]>=0,f'{op}: invalid counter {key}')
    require(report['discovered']==discovered and report['revoked']==len(revoked),f'{op}: changed inventory/revocation count')
    require(report['selected']==report['executed']==report['passed']==count,f'{op}: incomplete execution')
    require(all(report[k]==0 for k in ('failed','prefix_skipped','exception_skipped','selection_skipped')),f'{op}: required failure/exclusion')
    require(report.get('source_git_blob')==form['git_blob'],f'{op}: changed physical source')
    require(report.get('identity_sha256')==hashlib.sha256(raw).hexdigest(),f'{op}: changed identities')
    identities=json.loads(raw,object_pairs_hook=unique_object);require(isinstance(identities,list) and len(identities)==count,f'{op}: incomplete identities')
    indexes=set();categories=Counter()
    for item in identities:
        require(isinstance(item,dict) and set(item)=={'index','hash','category'},f'{op}: invalid identity record')
        index=item['index'];h=item['hash'];category=item['category']
        require(type(index) is int and 0<=index<discovered and index not in indexes and index not in revoked,f'{op}: duplicate/invalid/revoked index')
        require(isinstance(h,str) and len(h)==40 and all(c in '0123456789abcdef' for c in h) and h not in seen and h not in PINNED_REVOKED,f'{op}: duplicate/invalid/revoked hash')
        require(category in (('legacy','legacy_prefix') if op in LEGACY else ('new_form',)),f'{op}: invalid identity category')
        indexes.add(index);seen.add(h);categories[category]+=1
    require(indexes==set(range(discovered))-set(revoked)-omitted,f'{op}: incomplete evaluable index coverage')
    return count,categories


def summarize(directory,repo,forms_path=Path('docs/phase7_forms.json')):
    require_complete(forms_path)
    forms=json.loads(forms_path.read_text(),object_pairs_hook=unique_object)
    require(forms['corpus_revision']=='37c73caf53dcd22d3dd369ff09305d13d117a4fe','unpinned source inventory')
    required={f['opcode']:f for f in forms['forms'] if f['scope']=='required'}
    require({p.stem for p in (directory/'reports').glob('*.json')}==set(required),'missing/extra required reports')
    require({p.stem for p in (directory/'identities').glob('*.json')}==set(required),'missing/extra required identities')
    seen=set();totals=Counter();categories=Counter();revoked_found=set()
    for op,form in required.items():
        source=repo/form['file'];raw_source=source.read_bytes()
        blob=hashlib.sha1(b'blob '+str(len(raw_source)).encode()+b'\0'+raw_source).hexdigest()
        require(blob==form['git_blob'],f'{op}: changed pinned physical source')
        cases=load_source(source)
        require(len(cases)==form['case_count'],f'{op}: changed source population')
        revoked={c.index:c.test_hash for c in cases if c.test_hash in PINNED_REVOKED};revoked_found.update(revoked.values())
        if op in ('C6','C7','C8'):
            require(len(revoked)==1,f'{op}: original revocation missing')
        report=json.loads((directory/'reports'/(op+'.json')).read_text(),object_pairs_hook=unique_object)
        _,cohort=validate_report(report,form,(directory/'identities'/(op+'.json')).read_bytes(),revoked,seen);categories.update(cohort)
        actual={item['index']:item['hash'] for item in json.loads((directory/'identities'/(op+'.json')).read_text())}
        expected={c.index:c.test_hash for c in cases if c.index not in revoked and not (op=='E7' and c.index==CAPTURE['index'])}
        require(actual==expected,f'{op}: execution identities differ from pinned raw source')
        if op=='E7':
            from tools.run_singlestep import prepare_case
            _,_,dispositions=prepare_population([c for c in cases if c.index==CAPTURE['index']],op,source,lambda c:prepare_case(c,op,True,True))
            require(dispositions==[CAPTURE],'E7 no longer has verified missing evidence')
        totals.update({k:report[k] for k in ('discovered','revoked','executed','passed','failed')})
    require(revoked_found==PINNED_REVOKED,'changed original revocation set')
    require(dict(totals)=={'discovered':1387000,'revoked':3,'executed':1386996,'passed':1386996,'failed':0},'incomplete all-family physical counts')
    require(dict(categories)=={'legacy':474049,'legacy_prefix':43951,'new_form':868996},'non-disjoint physical categories')
    require(len(seen)==1386996,'incomplete unique physical identities')
    return dict(schema_version=2,validation='PASS',scope='complete-required-phase7-evaluable-cohort',totals=dict(totals),categories=dict(categories),unique_cases=len(seen),opcode_files=307,required_population=1386997,not_evaluable=[CAPTURE],unexpected_omissions=0)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--directory',type=Path,required=True);p.add_argument('--repo',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    result=summarize(a.directory,a.repo);a.output.write_text(json.dumps(result,indent=2)+'\n');print('PHASE7_COMPLETE_CORPUS PASS: 1386996 evaluable passes; 1 NOT EVALUABLE; required population 1386997; all 307 required files')

if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyError,TypeError) as error:raise SystemExit('PHASE7_COMPLETE_CORPUS FAIL: '+str(error))
