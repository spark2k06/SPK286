"""Require every adjust capture and identities disjoint from prior increments."""
import argparse
from collections import Counter
import json
from pathlib import Path
from tools.phase6_reports import require, unique_object
from tools.phase7_scalar_reports import validate_report
from tools.phase7_shift_reports import validate_identities
from tools.phase7_unary_reports import summarize as summarize_unary
from tools.run_singlestep import ADJUST_OPCODES

COHORT = ADJUST_OPCODES


def summarize(directory, unary_directory, data_directory, shift_directory, scalar_directory, byte_directory, forms_path=Path('docs/phase7_forms.json')):
    prior = summarize_unary(unary_directory, data_directory, shift_directory, scalar_directory, byte_directory, forms_path)
    forms = json.loads(forms_path.read_text(), object_pairs_hook=unique_object)
    manifest = {f['opcode']: f for f in forms['forms']}
    require({p.stem for p in (directory/'reports').glob('*.json')} == set(COHORT), 'missing/extra adjust reports')
    require({p.stem for p in (directory/'identities').glob('*.json')} == set(COHORT), 'missing/extra adjust identities')
    seen = set()
    for source in (byte_directory, scalar_directory, shift_directory, data_directory, unary_directory):
        for path in (source/'identities').glob('*.json'):
            seen.update(item['hash'] for item in json.loads(path.read_text(), object_pairs_hook=unique_object))
    require(len(seen) == 1098998, 'incomplete prior identity cohort')
    totals = Counter()
    reports = []
    for opcode in COHORT:
        report = json.loads((directory/'reports'/(opcode+'.json')).read_text(), object_pairs_hook=unique_object)
        count = validate_report(report, opcode, manifest[opcode])
        validate_identities((directory/'identities'/(opcode+'.json')).read_bytes(), report, count, seen)
        totals.update({k: report[k] for k in ('discovered', 'revoked', 'executed', 'passed', 'failed')})
        reports.append({'opcode':opcode, 'executed':count, 'source_git_blob':report['source_git_blob'], 'identity_sha256':report['identity_sha256']})
    require(dict(totals) == {'discovered':30000, 'revoked':0, 'executed':30000, 'passed':30000, 'failed':0}, 'adjust totals changed')
    require(len(seen) == 1128998, 'non-disjoint combined cohort')
    return {'schema_version':1, 'validation':'PASS', 'scope':'adjust-increment-only', 'full_phase7':'incomplete',
            'adjust_totals':dict(totals), 'prior_combined_passed':prior['combined_passed'], 'combined_passed':len(seen), 'opcodes':reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--unary-directory', type=Path, required=True)
    parser.add_argument('--data-directory', type=Path, required=True)
    parser.add_argument('--shift-directory', type=Path, required=True)
    parser.add_argument('--scalar-directory', type=Path, required=True)
    parser.add_argument('--byte-directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = summarize(args.directory, args.unary_directory, args.data_directory, args.shift_directory, args.scalar_directory, args.byte_directory)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True)+'\n')
    print('PHASE7_ADJUST_CORPUS PASS: 1098998 prior + 30000 adjust = 1128998 disjoint cases')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f'PHASE7_ADJUST_CORPUS ERROR: {error}')
