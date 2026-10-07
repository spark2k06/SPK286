"""Run every supported SingleStep opcode file and fail on any failure or exclusion.

Every admitted case of each supported file is executed, including prefixed and
exception-terminated cases. The only accepted non-pass is the single known
incomplete physical capture recognized by ``tools.singlestep_admission``.
"""
import argparse
from collections import Counter
import contextlib
import json
from pathlib import Path
import time

from tools.report_checks import unique_object
from tools.run_singlestep import SUPPORTED_OPCODES, run_opcode, SingleStepRunnerError
from tools.singlestep import load_revocation_list
from tools.singlestep_admission import validate_dispositions

KEYS = ('discovered', 'revoked', 'prefix_skipped', 'exception_skipped',
        'selection_skipped', 'executed', 'passed', 'failed')


def run_all(opcodes, execute):
    records = []
    totals = Counter()
    errors = []
    for opcode in opcodes:
        started = time.time()
        try:
            values = execute(opcode)
            if len(values) != len(KEYS) or any(type(v) is not int or v < 0 for v in values):
                raise ValueError('malformed result counters')
            counts = dict(zip(KEYS, values))
            totals.update(counts)
            record = dict(opcode=opcode, counts=counts)
            if counts['failed'] or any(counts[k] for k in ('prefix_skipped', 'exception_skipped', 'selection_skipped')):
                errors.append(dict(opcode=opcode, error='execution failed or cases were excluded'))
        except (SingleStepRunnerError, OSError, ValueError) as error:
            record = dict(opcode=opcode, error=str(error))
            errors.append(dict(record))
        record.update(start=started, end=time.time())
        records.append(record)
    return dict(validation='FAIL' if errors else 'PASS', totals=dict(totals), errors=errors, records=records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--opcode', action='append', help='restrict the run to these opcode files')
    args = parser.parse_args()
    opcodes = tuple(args.opcode) if args.opcode else SUPPORTED_OPCODES
    unknown = sorted(set(opcodes) - set(SUPPORTED_OPCODES))
    if unknown:
        raise ValueError(f'unsupported opcode files: {unknown}')
    if args.build_dir.exists():
        raise ValueError('choose a previously absent output directory')
    if not args.executable.is_file():
        raise ValueError('missing simulator executable')
    args.build_dir.mkdir(parents=True)
    logs = args.build_dir / 'family-logs'
    logs.mkdir()
    revoked = load_revocation_list(args.repo / 'revocation_list.txt')
    args.include_exceptions = True
    args.include_prefixes = True
    args.full = True
    args.sample = None
    args.index = None
    args.test_hash = None
    args.trace = None

    def execute(opcode):
        with (logs / (opcode + '.log')).open('w') as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
            return run_opcode(opcode, args.repo, revoked, args, args.build_dir, args.executable.resolve())

    summary = run_all(opcodes, execute)
    dispositions = []
    for record in summary['records']:
        if 'error' in record:
            continue
        report_path = args.build_dir / 'singlestep/reports' / (record['opcode'] + '.json')
        report = json.loads(report_path.read_text(), object_pairs_hook=unique_object)
        try:
            validate_dispositions(report.get('not_evaluable', []), record['opcode'])
        except ValueError as error:
            summary['errors'].append(dict(opcode=record['opcode'], error=str(error)))
        dispositions.extend(report.get('not_evaluable', []))
    summary['not_evaluable'] = dispositions
    if summary['errors']:
        summary['validation'] = 'FAIL'
    (args.build_dir / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    totals = summary['totals']
    print(f"SINGLESTEP {summary['validation']}: {len(summary['records'])} files, "
          f"{totals.get('executed', 0)} executed, {totals.get('passed', 0)} passed, "
          f"{totals.get('failed', 0)} failed, {len(dispositions)} not evaluable, "
          f"{totals.get('revoked', 0)} revoked; errors={len(summary['errors'])}")
    for error in summary['errors']:
        print(json.dumps(error))
    return 0 if summary['validation'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
