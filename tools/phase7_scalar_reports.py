"""Strict scalar increment accounting, disjoint from the frozen byte/prefix cohort."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
from tools.phase6_reports import require, unique_object
from tools.phase7_reports import summarize as summarize_bytes
from tools.run_singlestep import TEST_OPCODES, SCALAR_DIRECT_OPCODES

COHORT = TEST_OPCODES + SCALAR_DIRECT_OPCODES


def validate_report(report, opcode, form):
    require(report.get('opcode') == opcode, 'wrong scalar opcode report')
    for key in ('discovered','revoked','prefix_skipped','exception_skipped','selection_skipped','selected','executed','passed','failed'):
        require(type(report.get(key)) is int and report[key] >= 0, f'{opcode}: invalid {key}')
    count = form['case_count']
    require(report['discovered'] == count, f'{opcode}: incomplete source inventory')
    require(report['revoked'] == report['prefix_skipped'] == report['exception_skipped'] == report['selection_skipped'] == report['failed'] == 0, f'{opcode}: excluded or failed required cases')
    require(report['selected'] == report['executed'] == report['passed'] == count, f'{opcode}: incomplete scalar execution')
    require(report.get('source_git_blob') == form['git_blob'], f'{opcode}: changed corpus source')
    return count


def summarize(directory, byte_directory, forms_path=Path('docs/phase7_forms.json')):
    prior = summarize_bytes(byte_directory, forms_path)
    forms = json.loads(forms_path.read_text(), object_pairs_hook=unique_object)
    manifest = {f['opcode']: f for f in forms['forms']}
    reports_dir = directory/'reports'
    identities_dir = directory/'identities'
    require({p.stem for p in reports_dir.glob('*.json')} == set(COHORT), 'missing/extra scalar reports')
    seen = set()
    for path in (byte_directory/'identities').glob('*.json'):
        seen.update(item['hash'] for item in json.loads(path.read_text(), object_pairs_hook=unique_object))
    require(len(seen) == 737998, 'incomplete prior identity cohort')
    totals = Counter()
    reports = []
    for opcode in COHORT:
        report = json.loads((reports_dir/(opcode+'.json')).read_text(), object_pairs_hook=unique_object)
        count = validate_report(report, opcode, manifest[opcode])
        raw = (identities_dir/(opcode+'.json')).read_bytes()
        require(hashlib.sha256(raw).hexdigest() == report.get('identity_sha256'), f'{opcode}: changed identity report')
        identities = json.loads(raw, object_pairs_hook=unique_object)
        require(isinstance(identities,list) and len(identities) == count, f'{opcode}: incomplete identities')
        indexes = set()
        for item in identities:
            require(set(item) == {'index','hash','category'}, f'{opcode}: identity fields')
            require(type(item['index']) is int and 0 <= item['index'] < count and item['index'] not in indexes, f'{opcode}: duplicate/invalid index')
            require(isinstance(item['hash'],str) and len(item['hash']) == 40 and all(c in '0123456789abcdef' for c in item['hash']) and item['hash'] not in seen, f'{opcode}: duplicate/invalid hash')
            require(item['category'] == 'new_form', f'{opcode}: wrong scalar category')
            indexes.add(item['index']); seen.add(item['hash'])
        totals.update({k: report[k] for k in ('discovered','revoked','executed','passed','failed')})
        reports.append({'opcode':opcode,'executed':count,'source_git_blob':report['source_git_blob'],'identity_sha256':report['identity_sha256']})
    require(dict(totals) == {'discovered':63000,'revoked':0,'executed':63000,'passed':63000,'failed':0}, 'scalar totals changed')
    require(len(seen) == 800998, 'non-disjoint combined cohort')
    return {'schema_version':1,'validation':'PASS','scope':'scalar-increment-only','full_phase7':'incomplete',
            'scalar_totals':dict(totals),'prior_totals':prior['totals'],'combined_passed':len(seen),'opcodes':reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--byte-directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = summarize(args.directory, args.byte_directory)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True)+'\n')
    print('PHASE7_SCALAR_CORPUS PASS: 737998 prior + 63000 new scalar = 800998 disjoint cases')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f'PHASE7_SCALAR_CORPUS ERROR: {error}')
