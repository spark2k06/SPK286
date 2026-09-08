"""Do not turn agreement with provisional model policies into a release pass."""
import argparse
import json
from pathlib import Path
from tools.phase6_reports import unique_object


def validate(path):
    document=json.loads(path.read_text(),object_pairs_hook=unique_object)
    if document.get('schema')!=1 or document.get('phase')!=6:
        raise ValueError('invalid Phase 6 evidence schema')
    decisions=document.get('decisions')
    if not isinstance(decisions,list) or {d.get('id') for d in decisions}!={'failed-iret-nmi','sti-old-if','fault-tf'} or len(decisions)!=3:
        raise ValueError('missing/duplicate architectural decisions')
    unresolved=[]
    for decision in decisions:
        if decision.get('status')!='resolved':
            unresolved.append(decision['id'])
        elif not decision.get('resolution') or not decision.get('primary_or_physical_evidence'):
            raise ValueError(f"{decision['id']}: resolution requires identified primary/physical evidence")
    if unresolved:
        raise ValueError('unresolved 286 evidence: '+', '.join(unresolved))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence',type=Path,default=Path('docs/phase6_evidence.json'))
    args=parser.parse_args()
    try:
        validate(args.evidence)
    except (ValueError,OSError,TypeError,KeyError) as error:
        raise SystemExit(f'PHASE6_EVIDENCE_BLOCKED: {error}')
    print('PHASE6_EVIDENCE PASS: identified architectural decisions resolved')


if __name__=='__main__':main()
