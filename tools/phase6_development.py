"""Validate the narrow Phase 6 provisional-development evidence contract.

This does not resolve evidence or replace tools.phase6_evidence's strict gate.
Only the three recorded policies may remain unresolved. Malformed evidence is
an error, including in CI; it is never classified as expected pending evidence.
"""
import argparse
import json
from pathlib import Path

from tools.phase6_evidence import validate as validate_architecture
from tools.phase6_reports import unique_object


POLICIES = {
    'failed-iret-nmi': (
        'NMI inhibition is released when IRET starts, including an attempt that later faults.',
        'A primary 80286 clarification or physical 80286 trace distinguishing a successful IRET from a faulting attempt.'),
    'sti-old-if': (
        'STI creates the following-instruction shadow only when old IF was zero.',
        '286-specific evidence for STI entered with IF=1 and for consecutive STI instructions.'),
    'fault-tf': (
        'A faulting instruction does not create a new retirement-based TF trap.',
        'Resolve the conflict between Real Mode entry/completion text and Appendix C/D instruction-exception single-step wording.'),
}
REFERENCE = 'docs/PHASE6_ARCHITECTURAL_REVIEW.md'


def validate(path):
    document = json.loads(path.read_text(), object_pairs_hook=unique_object)
    if not isinstance(document, dict) or set(document) != {'schema', 'phase', 'decisions'}:
        raise ValueError('invalid evidence document fields')
    if type(document['schema']) is not int or document['schema'] != 1 or type(document['phase']) is not int or document['phase'] != 6:
        raise ValueError('invalid Phase 6 evidence schema')
    decisions = document['decisions']
    if not isinstance(decisions, list) or len(decisions) != len(POLICIES):
        raise ValueError('missing/duplicate architectural decisions')
    seen = set()
    pending = []
    for decision in decisions:
        if not isinstance(decision, dict):
            raise ValueError('architectural decision must be an object')
        name = decision.get('id')
        if not isinstance(name, str) or name not in POLICIES or name in seen:
            raise ValueError('missing/duplicate/unapproved architectural decision')
        seen.add(name)
        required = {'id', 'status', 'candidate', 'required_evidence', 'reference'}
        allowed = required | {'resolution', 'primary_or_physical_evidence'}
        if not required <= set(decision) or not set(decision) <= allowed:
            raise ValueError(f'{name}: invalid decision fields')
        if (decision['candidate'], decision['required_evidence']) != POLICIES[name] or decision['reference'] != REFERENCE:
            raise ValueError(f'{name}: recorded policy or evidence reference changed')
        if decision['status'] == 'unresolved':
            if set(decision) != required:
                raise ValueError(f'{name}: unresolved decision has resolution fields')
            pending.append(name)
        elif decision['status'] == 'resolved':
            for field in ('resolution', 'primary_or_physical_evidence'):
                if not isinstance(decision.get(field), str) or not decision[field].strip():
                    raise ValueError(f'{name}: resolution requires identified primary/physical evidence')
        else:
            raise ValueError(f'{name}: invalid evidence status')
    return tuple(name for name in POLICIES if name in pending)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=Path('docs/phase6_evidence.json'))
    parser.add_argument('--ci-status', action='store_true', help='classify strict evidence result; no executable-validation claim')
    args = parser.parse_args()
    pending = validate(args.evidence)
    if args.ci_status:
        # Validate the exact expected strict failure, not merely a nonzero exit.
        if pending:
            expected = 'unresolved 286 evidence: ' + ', '.join(pending)
            try:
                validate_architecture(args.evidence)
            except ValueError as error:
                if str(error) != expected:
                    raise
            else:
                raise ValueError('strict architectural gate accepted unresolved evidence')
        else:
            validate_architecture(args.evidence)
    if pending:
        print('PHASE6_ARCHITECTURAL_EVIDENCE_PENDING: ' + ','.join(pending))
    else:
        print('PHASE6_ARCHITECTURAL_EVIDENCE_RESOLVED: strict release checks and independent approval remain separate')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, TypeError, KeyError) as error:
        raise SystemExit(f'PHASE6_DEVELOPMENT_EVIDENCE_FAIL: {error}')
