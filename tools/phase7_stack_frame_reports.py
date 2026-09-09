"""Require every stack/frame capture and identities disjoint from prior increments."""
import argparse
from collections import Counter
import json
from pathlib import Path
from tools.phase6_reports import require, unique_object
import hashlib
from tools.phase7_segment_reports import summarize as summarize_segment
from tools.run_singlestep import STACK_FRAME_OPCODES

COHORT = STACK_FRAME_OPCODES
# Existing upstream revocation at the pinned 37c73caf revision, independently
# checked against the raw C8 record and revocation_list.txt. No local exclusion.
UPSTREAM_REVOKED = {'C8': {904: 'e64e6de35ca857a62a8f4ccc2bf991700a564b28'}}


def validate_capture(report, opcode, form, raw, seen):
    require(report.get('opcode') == opcode, 'wrong stack/frame opcode report')
    for key in ('discovered', 'revoked', 'prefix_skipped', 'exception_skipped', 'selection_skipped', 'selected', 'executed', 'passed', 'failed'):
        require(type(report.get(key)) is int and report[key] >= 0, f'{opcode}: invalid {key}')
    revoked = UPSTREAM_REVOKED.get(opcode, {})
    discovered = form['case_count']; count = discovered - len(revoked)
    require(report['discovered'] == discovered and report['revoked'] == len(revoked), f'{opcode}: inventory/revocation changed')
    require(report['prefix_skipped'] == report['exception_skipped'] == report['selection_skipped'] == report['failed'] == 0, f'{opcode}: excluded or failed required cases')
    require(report['selected'] == report['executed'] == report['passed'] == count, f'{opcode}: incomplete execution')
    require(report.get('source_git_blob') == form['git_blob'], f'{opcode}: changed corpus source')
    require(hashlib.sha256(raw).hexdigest() == report.get('identity_sha256'), f'{opcode}: changed identity report')
    identities = json.loads(raw, object_pairs_hook=unique_object)
    require(isinstance(identities, list) and len(identities) == count, f'{opcode}: incomplete identities')
    indexes = set()
    for item in identities:
        require(isinstance(item, dict) and set(item) == {'index', 'hash', 'category'}, f'{opcode}: identity fields')
        require(type(item['index']) is int and 0 <= item['index'] < discovered and item['index'] not in indexes and item['index'] not in revoked, f'{opcode}: duplicate/invalid/revoked index')
        require(isinstance(item['hash'], str) and len(item['hash']) == 40 and all(c in '0123456789abcdef' for c in item['hash']) and item['hash'] not in seen and item['hash'] not in revoked.values(), f'{opcode}: duplicate/invalid/revoked hash')
        require(item['category'] == 'new_form', f'{opcode}: wrong identity category')
        indexes.add(item['index']); seen.add(item['hash'])
    require(indexes == set(range(discovered)) - set(revoked), f'{opcode}: incomplete non-revoked index coverage')
    return count


def summarize(directory, segment_directory, adjust_directory, unary_directory, data_directory, shift_directory, scalar_directory, byte_directory, forms_path=Path('docs/phase7_forms.json')):
    prior = summarize_segment(segment_directory, adjust_directory, unary_directory, data_directory, shift_directory, scalar_directory, byte_directory, forms_path)
    forms = json.loads(forms_path.read_text(), object_pairs_hook=unique_object)
    manifest = {f['opcode']: f for f in forms['forms']}
    require({p.stem for p in (directory/'reports').glob('*.json')} == set(COHORT), 'missing/extra stack/frame reports')
    require({p.stem for p in (directory/'identities').glob('*.json')} == set(COHORT), 'missing/extra stack/frame identities')
    seen = set()
    for source in (byte_directory, scalar_directory, shift_directory, data_directory, unary_directory, adjust_directory, segment_directory):
        for path in (source/'identities').glob('*.json'):
            seen.update(item['hash'] for item in json.loads(path.read_text(), object_pairs_hook=unique_object))
    require(len(seen) == 1173998, 'incomplete prior identity cohort')
    totals = Counter()
    reports = []
    for opcode in COHORT:
        report = json.loads((directory/'reports'/(opcode+'.json')).read_text(), object_pairs_hook=unique_object)
        count = validate_capture(report, opcode, manifest[opcode], (directory/'identities'/(opcode+'.json')).read_bytes(), seen)
        totals.update({k: report[k] for k in ('discovered', 'revoked', 'executed', 'passed', 'failed')})
        reports.append({'opcode':opcode, 'executed':count, 'source_git_blob':report['source_git_blob'], 'identity_sha256':report['identity_sha256']})
    require(dict(totals) == {'discovered':25000, 'revoked':1, 'executed':24999, 'passed':24999, 'failed':0}, 'stack/frame totals changed')
    require(len(seen) == 1198997, 'non-disjoint combined cohort')
    return {'schema_version':1, 'validation':'PASS', 'scope':'stack-frame-increment-only', 'full_phase7':'incomplete',
            'stack_frame_totals':dict(totals), 'prior_combined_passed':prior['combined_passed'], 'combined_passed':len(seen), 'opcodes':reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--segment-directory', type=Path, required=True)
    parser.add_argument('--adjust-directory', type=Path, required=True)
    parser.add_argument('--unary-directory', type=Path, required=True)
    parser.add_argument('--data-directory', type=Path, required=True)
    parser.add_argument('--shift-directory', type=Path, required=True)
    parser.add_argument('--scalar-directory', type=Path, required=True)
    parser.add_argument('--byte-directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = summarize(args.directory, args.segment_directory, args.adjust_directory, args.unary_directory, args.data_directory, args.shift_directory, args.scalar_directory, args.byte_directory)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True)+'\n')
    print('PHASE7_STACK_FRAME_CORPUS PASS: 1173998 prior + 24999 stack/frame = 1198997 disjoint cases')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f'PHASE7_STACK_FRAME_CORPUS ERROR: {error}')
