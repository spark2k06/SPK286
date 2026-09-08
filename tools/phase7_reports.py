"""Strict disjoint accounting for the implemented byte/prefix increment."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
from tools.phase6_reports import require, unique_object
from tools.phase6_cohort import SUPPORTED_OPCODES as LEGACY
from tools.run_singlestep import BYTE_SCALAR_OPCODES

COHORT=LEGACY+BYTE_SCALAR_OPCODES

def summarize(directory,forms_path=Path('docs/phase7_forms.json')):
    forms=json.loads(forms_path.read_text(),object_pairs_hook=unique_object)
    manifest={f['opcode']:f for f in forms['forms']}
    require(len(manifest)==326,'missing/duplicate physical form inventory')
    require(forms['corpus_revision']=='37c73caf53dcd22d3dd369ff09305d13d117a4fe','unpinned corpus')
    reports_dir=directory/'reports';identities_dir=directory/'identities'
    require({p.stem for p in reports_dir.glob('*.json')}==set(COHORT),'missing/extra increment reports')
    totals=Counter();seen_hashes=set();reports=[]
    for opcode in COHORT:
        report=json.loads((reports_dir/(opcode+'.json')).read_text(),object_pairs_hook=unique_object)
        require(report.get('opcode')==opcode,'wrong opcode report')
        for key in ('discovered','revoked','prefix_skipped','exception_skipped','selection_skipped','selected','executed','passed','failed'):
            require(type(report.get(key)) is int and report[key]>=0,f'{opcode}: invalid counter {key}')
        require(report['discovered']==(1000 if opcode in ('F4','FA','FB') else 5000),f'{opcode}: source count')
        require(report['revoked']==(1 if opcode in ('C6','C7') else 0),f'{opcode}: revocation count')
        require(report['prefix_skipped']==report['exception_skipped']==report['selection_skipped']==report['failed']==0,f'{opcode}: excluded/failed required cases')
        require(report['selected']==report['executed']==report['passed']==report['discovered']-report['revoked'],f'{opcode}: incomplete execution')
        require(report.get('source_git_blob')==manifest[opcode]['git_blob'],f'{opcode}: changed source')
        raw=(identities_dir/(opcode+'.json')).read_bytes()
        require(hashlib.sha256(raw).hexdigest()==report.get('identity_sha256'),f'{opcode}: changed identity report')
        identities=json.loads(raw,object_pairs_hook=unique_object);indexes=set();categories=Counter()
        require(isinstance(identities,list) and len(identities)==report['executed'],f'{opcode}: incomplete identities')
        for item in identities:
            require(set(item)=={'index','hash','category'},f'{opcode}: identity fields')
            require(type(item['index']) is int and 0<=item['index']<report['discovered'] and item['index'] not in indexes,f'{opcode}: duplicate/invalid index')
            require(isinstance(item['hash'],str) and len(item['hash'])==40 and all(c in '0123456789abcdef' for c in item['hash']) and item['hash'] not in seen_hashes,f'{opcode}: duplicate/invalid hash')
            require(item['category'] in (('legacy','legacy_prefix') if opcode in LEGACY else ('new_form',)),f'{opcode}: non-disjoint category')
            indexes.add(item['index']);seen_hashes.add(item['hash']);categories[item['category']]+=1
        totals.update(categories)
        totals.update({k:report[k] for k in ('discovered','revoked','executed','passed','failed')})
        reports.append({'opcode':opcode,**dict(categories),'executed':report['executed'],'source_git_blob':report['source_git_blob'],'identity_sha256':report['identity_sha256']})
    require(dict(totals)=={'legacy':474049,'legacy_prefix':43951,'new_form':219998,'discovered':738000,'revoked':2,'executed':737998,'passed':737998,'failed':0},f'increment totals differ: {dict(totals)}')
    return {'schema_version':1,'validation':'PASS','scope':'byte-prefix-increment-only','full_phase7':'incomplete','totals':dict(totals),'opcodes':reports}

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--directory',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();report=summarize(args.directory);args.output.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
    print('PHASE7_BYTE_PREFIX_CORPUS PASS: 474049 legacy + 43951 readmitted prefixes + 219998 new forms = 737998')
if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyError,TypeError) as e:raise SystemExit(f'PHASE7_BYTE_PREFIX_CORPUS ERROR: {e}')
