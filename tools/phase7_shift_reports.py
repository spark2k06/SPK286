"""Require all shift captures and disjoint identities alongside the scalar gate."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
from tools.phase6_reports import require, unique_object
from tools.phase7_scalar_reports import summarize as summarize_scalars, validate_report
from tools.run_singlestep import SHIFT_OPCODES

COHORT = SHIFT_OPCODES


def validate_identities(raw, report, count, seen):
    opcode = report['opcode']
    require(hashlib.sha256(raw).hexdigest() == report.get('identity_sha256'), f'{opcode}: changed identity report')
    identities = json.loads(raw, object_pairs_hook=unique_object)
    require(isinstance(identities, list) and len(identities) == count, f'{opcode}: incomplete identities')
    indexes = set()
    for item in identities:
        require(isinstance(item, dict) and set(item) == {'index', 'hash', 'category'}, f'{opcode}: identity fields')
        require(type(item['index']) is int and 0 <= item['index'] < count and item['index'] not in indexes, f'{opcode}: duplicate/invalid index')
        require(isinstance(item['hash'], str) and len(item['hash']) == 40 and all(c in '0123456789abcdef' for c in item['hash']) and item['hash'] not in seen, f'{opcode}: duplicate/invalid hash')
        require(item['category'] == 'new_form', f'{opcode}: wrong shift category')
        indexes.add(item['index']); seen.add(item['hash'])


def summarize(directory, scalar_directory, byte_directory, forms_path=Path('docs/phase7_forms.json')):
    prior = summarize_scalars(scalar_directory, byte_directory, forms_path)
    forms = json.loads(forms_path.read_text(), object_pairs_hook=unique_object)
    manifest = {f['opcode']: f for f in forms['forms']}
    require({p.stem for p in (directory/'reports').glob('*.json')} == set(COHORT), 'missing/extra shift reports')
    require({p.stem for p in (directory/'identities').glob('*.json')} == set(COHORT), 'missing/extra shift identities')
    seen = set()
    for source in (byte_directory, scalar_directory):
        for path in (source/'identities').glob('*.json'):
            seen.update(item['hash'] for item in json.loads(path.read_text(), object_pairs_hook=unique_object))
    require(len(seen) == 800998, 'incomplete prior identity cohort')
    totals = Counter()
    reports = []
    for opcode in COHORT:
        report = json.loads((directory/'reports'/(opcode+'.json')).read_text(), object_pairs_hook=unique_object)
        count = validate_report(report, opcode, manifest[opcode])
        validate_identities((directory/'identities'/(opcode+'.json')).read_bytes(), report, count, seen)
        totals.update({k: report[k] for k in ('discovered', 'revoked', 'executed', 'passed', 'failed')})
        reports.append({'opcode':opcode, 'executed':count, 'source_git_blob':report['source_git_blob'], 'identity_sha256':report['identity_sha256']})
    require(dict(totals) == {'discovered':210000, 'revoked':0, 'executed':210000, 'passed':210000, 'failed':0}, 'shift totals changed')
    require(len(seen) == 1010998, 'non-disjoint combined cohort')
    return {'schema_version':1, 'validation':'PASS', 'scope':'shift-increment-only', 'full_phase7':'incomplete',
            'shift_totals':dict(totals), 'prior_combined_passed':prior['combined_passed'], 'combined_passed':len(seen), 'opcodes':reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--scalar-directory', type=Path, required=True)
    parser.add_argument('--byte-directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = summarize(args.directory, args.scalar_directory, args.byte_directory)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True)+'\n')
    print('PHASE7_SHIFT_CORPUS PASS: 800998 prior + 210000 shifts = 1010998 disjoint cases')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f'PHASE7_SHIFT_CORPUS ERROR: {error}')
