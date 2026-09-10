"""Require every memory-string capture and identities disjoint from prior increments."""
import argparse
from collections import Counter
import json
from pathlib import Path
from tools.phase6_reports import require, unique_object
import hashlib
from tools.phase7_arithmetic_reports import summarize as summarize_arithmetic
from tools.phase7_stack_frame_reports import validate_capture
from tools.run_singlestep import STRING_OPCODES

COHORT = STRING_OPCODES
def summarize(directory, arithmetic_directory, far_directory, stack_frame_directory, segment_directory, adjust_directory, unary_directory, data_directory, shift_directory, scalar_directory, byte_directory, forms_path=Path('docs/phase7_forms.json')):
    prior = summarize_arithmetic(arithmetic_directory, far_directory, stack_frame_directory, segment_directory, adjust_directory, unary_directory, data_directory, shift_directory, scalar_directory, byte_directory, forms_path)
    forms = json.loads(forms_path.read_text(), object_pairs_hook=unique_object)
    manifest = {f['opcode']: f for f in forms['forms']}
    require({p.stem for p in (directory/'reports').glob('*.json')} == set(COHORT), 'missing/extra memory-string reports')
    require({p.stem for p in (directory/'identities').glob('*.json')} == set(COHORT), 'missing/extra memory-string identities')
    seen = set()
    for source in (byte_directory, scalar_directory, shift_directory, data_directory, unary_directory, adjust_directory, segment_directory, stack_frame_directory, far_directory, arithmetic_directory):
        for path in (source/'identities').glob('*.json'):
            seen.update(item['hash'] for item in json.loads(path.read_text(), object_pairs_hook=unique_object))
    require(len(seen) == 1288997, 'incomplete prior identity cohort')
    totals = Counter()
    reports = []
    for opcode in COHORT:
        report = json.loads((directory/'reports'/(opcode+'.json')).read_text(), object_pairs_hook=unique_object)
        count = validate_capture(report, opcode, manifest[opcode], (directory/'identities'/(opcode+'.json')).read_bytes(), seen)
        totals.update({k: report[k] for k in ('discovered', 'revoked', 'executed', 'passed', 'failed')})
        reports.append({'opcode':opcode, 'executed':count, 'source_git_blob':report['source_git_blob'], 'identity_sha256':report['identity_sha256']})
    require(dict(totals) == {'discovered':50000, 'revoked':0, 'executed':50000, 'passed':50000, 'failed':0}, 'memory-string totals changed')
    require(len(seen) == 1338997, 'non-disjoint combined cohort')
    return {'schema_version':1, 'validation':'PASS', 'scope':'memory-string-increment-only', 'full_phase7':'incomplete',
            'string_totals':dict(totals), 'prior_combined_passed':prior['combined_passed'], 'combined_passed':len(seen), 'opcodes':reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--arithmetic-directory', type=Path, required=True)
    parser.add_argument('--far-directory', type=Path, required=True)
    parser.add_argument('--stack-frame-directory', type=Path, required=True)
    parser.add_argument('--segment-directory', type=Path, required=True)
    parser.add_argument('--adjust-directory', type=Path, required=True)
    parser.add_argument('--unary-directory', type=Path, required=True)
    parser.add_argument('--data-directory', type=Path, required=True)
    parser.add_argument('--shift-directory', type=Path, required=True)
    parser.add_argument('--scalar-directory', type=Path, required=True)
    parser.add_argument('--byte-directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = summarize(args.directory, args.arithmetic_directory, args.far_directory, args.stack_frame_directory, args.segment_directory, args.adjust_directory, args.unary_directory, args.data_directory, args.shift_directory, args.scalar_directory, args.byte_directory)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True)+'\n')
    print('PHASE7_STRING_CORPUS PASS: 1288997 prior + 50000 memory-string = 1338997 disjoint cases')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f'PHASE7_STRING_CORPUS ERROR: {error}')
