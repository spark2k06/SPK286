"""Require every far-control capture and identities disjoint from prior increments."""
import argparse
from collections import Counter
import json
from pathlib import Path
from tools.phase6_reports import require, unique_object
import hashlib
from tools.phase7_stack_frame_reports import summarize as summarize_stack_frame, validate_capture
from tools.run_singlestep import FAR_OPCODES

COHORT = FAR_OPCODES
def summarize(directory, stack_frame_directory, segment_directory, adjust_directory, unary_directory, data_directory, shift_directory, scalar_directory, byte_directory, forms_path=Path('docs/phase7_forms.json')):
    prior = summarize_stack_frame(stack_frame_directory, segment_directory, adjust_directory, unary_directory, data_directory, shift_directory, scalar_directory, byte_directory, forms_path)
    forms = json.loads(forms_path.read_text(), object_pairs_hook=unique_object)
    manifest = {f['opcode']: f for f in forms['forms']}
    require({p.stem for p in (directory/'reports').glob('*.json')} == set(COHORT), 'missing/extra far-control reports')
    require({p.stem for p in (directory/'identities').glob('*.json')} == set(COHORT), 'missing/extra far-control identities')
    seen = set()
    for source in (byte_directory, scalar_directory, shift_directory, data_directory, unary_directory, adjust_directory, segment_directory, stack_frame_directory):
        for path in (source/'identities').glob('*.json'):
            seen.update(item['hash'] for item in json.loads(path.read_text(), object_pairs_hook=unique_object))
    require(len(seen) == 1198997, 'incomplete prior identity cohort')
    totals = Counter()
    reports = []
    for opcode in COHORT:
        report = json.loads((directory/'reports'/(opcode+'.json')).read_text(), object_pairs_hook=unique_object)
        count = validate_capture(report, opcode, manifest[opcode], (directory/'identities'/(opcode+'.json')).read_bytes(), seen)
        totals.update({k: report[k] for k in ('discovered', 'revoked', 'executed', 'passed', 'failed')})
        reports.append({'opcode':opcode, 'executed':count, 'source_git_blob':report['source_git_blob'], 'identity_sha256':report['identity_sha256']})
    require(dict(totals) == {'discovered':40000, 'revoked':0, 'executed':40000, 'passed':40000, 'failed':0}, 'far-control totals changed')
    require(len(seen) == 1238997, 'non-disjoint combined cohort')
    return {'schema_version':1, 'validation':'PASS', 'scope':'far-control-increment-only', 'full_phase7':'incomplete',
            'far_totals':dict(totals), 'prior_combined_passed':prior['combined_passed'], 'combined_passed':len(seen), 'opcodes':reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
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
    report = summarize(args.directory, args.stack_frame_directory, args.segment_directory, args.adjust_directory, args.unary_directory, args.data_directory, args.shift_directory, args.scalar_directory, args.byte_directory)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True)+'\n')
    print('PHASE7_FAR_CORPUS PASS: 1198997 prior + 40000 far-control = 1238997 disjoint cases')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f'PHASE7_FAR_CORPUS ERROR: {error}')
