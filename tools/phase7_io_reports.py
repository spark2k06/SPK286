"""Require every scalar/string I/O capture and identities disjoint from prior increments."""
import argparse
from collections import Counter
import json
from pathlib import Path
from tools.phase6_reports import require, unique_object
import hashlib
from tools.phase7_string_reports import summarize as summarize_string
from tools.phase7_complete_reports import validate_report
from tools.phase7_capture_admission import CAPTURE
from tools.run_singlestep import IO_OPCODES

COHORT = IO_OPCODES
def summarize(directory, string_directory, arithmetic_directory, far_directory, stack_frame_directory, segment_directory, adjust_directory, unary_directory, data_directory, shift_directory, scalar_directory, byte_directory, forms_path=Path('docs/phase7_forms.json')):
    prior = summarize_string(string_directory, arithmetic_directory, far_directory, stack_frame_directory, segment_directory, adjust_directory, unary_directory, data_directory, shift_directory, scalar_directory, byte_directory, forms_path)
    forms = json.loads(forms_path.read_text(), object_pairs_hook=unique_object)
    manifest = {f['opcode']: f for f in forms['forms']}
    require({p.stem for p in (directory/'reports').glob('*.json')} == set(COHORT), 'missing/extra scalar-and-string-io reports')
    require({p.stem for p in (directory/'identities').glob('*.json')} == set(COHORT), 'missing/extra scalar-and-string-io identities')
    seen = set()
    for source in (byte_directory, scalar_directory, shift_directory, data_directory, unary_directory, adjust_directory, segment_directory, stack_frame_directory, far_directory, arithmetic_directory, string_directory):
        for path in (source/'identities').glob('*.json'):
            seen.update(item['hash'] for item in json.loads(path.read_text(), object_pairs_hook=unique_object))
    require(len(seen) == 1338997, 'incomplete prior identity cohort')
    totals = Counter()
    reports = []
    for opcode in COHORT:
        report = json.loads((directory/'reports'/(opcode+'.json')).read_text(), object_pairs_hook=unique_object)
        count,_ = validate_report(report, manifest[opcode], (directory/'identities'/(opcode+'.json')).read_bytes(), {}, seen)
        totals.update({k: report[k] for k in ('discovered', 'revoked', 'executed', 'passed', 'failed')})
        reports.append({'opcode':opcode, 'executed':count, 'source_git_blob':report['source_git_blob'], 'identity_sha256':report['identity_sha256']})
    require(dict(totals) == {'discovered':48000, 'revoked':0, 'executed':47999, 'passed':47999, 'failed':0}, 'scalar-and-string-io totals changed')
    require(len(seen) == 1386996, 'non-disjoint combined cohort')
    return {'schema_version':2, 'validation':'PASS', 'scope':'scalar-and-string-io-increment-only', 'full_phase7':'requires-functional-gate', 'not_evaluable':[CAPTURE],
            'io_totals':dict(totals), 'prior_combined_passed':prior['combined_passed'], 'combined_passed':len(seen), 'opcodes':reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--string-directory', type=Path, required=True)
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
    report = summarize(args.directory, args.string_directory, args.arithmetic_directory, args.far_directory, args.stack_frame_directory, args.segment_directory, args.adjust_directory, args.unary_directory, args.data_directory, args.shift_directory, args.scalar_directory, args.byte_directory)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True)+'\n')
    print('PHASE7_IO_CORPUS PASS: 1338997 prior + 47999 scalar-and-string-io = 1386996 evaluable passes; 1 NOT EVALUABLE')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f'PHASE7_IO_CORPUS ERROR: {error}')
