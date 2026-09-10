"""Versioned exact evidence-note contract and immutable acceptance inputs."""
import argparse
import hashlib
import json
from pathlib import Path

from tools.phase6_reports import require, unique_object
from tools.phase7_capture_admission import CAPTURE

ROOT = Path(__file__).resolve().parents[1]
STATUSES = {
    'failed-iret-nmi': 'open_inherited_policy',
    'sti-old-if': 'open_inherited_policy',
    'fault-tf': 'open_inherited_policy',
    'rep-zero-count-event-order': 'open_engineering_policy',
    'e7-incomplete-physical-capture': 'open_incomplete_capture',
    'rep-tf-granularity': 'resolved_documentary_with_inference',
}
BASE_INPUTS = {
    'docs/PHASE7_FUNCTIONAL_POLICY.md', 'docs/phase7_evidence_notes.json',
    'docs/phase7_forms.json', 'docs/phase6_evidence.json',
    'docs/phase6_provisional_baseline.json',
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    return json.loads(path.read_text(), object_pairs_hook=unique_object)


def verify_artifact(item, root=None):
    root = ROOT if root is None else root
    require(isinstance(item, dict) and set(item) == {'path', 'sha256'}, 'malformed evidence artifact')
    name, digest = item['path'], item['sha256']
    require(isinstance(name, str) and isinstance(digest, str), 'malformed evidence path/hash')
    path = (root / name).resolve()
    require(not Path(name).is_absolute() and path.is_relative_to(root.resolve())
            and path.is_file(), 'missing or out-of-repository evidence artifact')
    require(sha256(path) == digest, 'changed evidence artifact: ' + name)
    return path


def check_notes(path=None, root=None):
    root = ROOT if root is None else root
    record = read_json(path or root / 'docs/phase7_evidence_notes.json')
    require(set(record) == {'schema_version', 'authorization', 'notes', 'capture'}
            and type(record['schema_version']) is int and record['schema_version'] == 1
            and record['authorization'] == 'D-037', 'malformed evidence-note register')
    notes = record['notes']
    require(isinstance(notes, list) and len(notes) == len(STATUSES)
            and {n['id'] for n in notes} == set(STATUSES), 'unknown, duplicate or missing evidence note')
    require(record['capture'] == CAPTURE, 'changed authorized capture disposition')
    for note in notes:
        require(set(note) == {'id', 'status', 'selected_policy', 'provenance',
                             'executable_coverage', 'future_evidence', 'review_disposition', 'evidence'},
                'malformed evidence note')
        require(note['status'] == STATUSES[note['id']], 'unauthorized evidence status')
        require(note['review_disposition'] == 'requires_bound_independent_functional_review',
                'invalid evidence review disposition')
        for field in ('selected_policy', 'provenance', 'executable_coverage', 'future_evidence'):
            require(isinstance(note[field], str) and bool(note[field].strip()), 'missing note ' + field)
        require(isinstance(note['evidence'], list) and bool(note['evidence']), 'missing evidence artifacts')
        for item in note['evidence']:
            verify_artifact(item, root)
    return record


def snapshot(root=None):
    root = ROOT if root is None else root
    record = check_notes(root=root)
    names = BASE_INPUTS | {item['path'] for note in record['notes'] for item in note['evidence']}
    return {name: sha256(root / name) for name in sorted(names)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--strict-evidence', action='store_true')
    args = parser.parse_args()
    current = snapshot()
    if args.manifest:
        if args.check:
            require(read_json(args.manifest) == current, 'acceptance-policy inputs changed')
        else:
            args.manifest.write_text(json.dumps(current, indent=2, sort_keys=True) + '\n')
    print('PHASE7_POLICY PASS: exact D-037 register; five open notes; resolved nonzero REP TF disposition preserved')
    if args.strict_evidence:
        raise ValueError('physical evidence remains open: ' + ', '.join(k for k,v in STATUSES.items() if v.startswith('open_')))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit('PHASE7_EVIDENCE_INCOMPLETE: ' + str(error))
