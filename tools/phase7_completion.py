"""Independent functional approval, bound to tested source and D-037 policy."""
import argparse
from pathlib import Path
from tools.phase6_reports import require
from tools import phase7_policy
from tools.phase7_policy import read_json, sha256, verify_artifact

ROOT=Path(__file__).resolve().parents[1]
SCOPE='phase7-functional-development'


def check(path, manifest, policy_manifest, result):
    phase7_policy.check_notes(root=ROOT)
    require(read_json(policy_manifest)==phase7_policy.snapshot(root=ROOT), 'acceptance-policy inputs changed')
    record=read_json(path)
    require(set(record)=={'schema_version','implementer','independent_review'}
            and type(record['schema_version']) is int and record['schema_version']==2,
            'malformed functional completion record')
    implementer=record['implementer']
    require(isinstance(implementer,str) and bool(implementer.strip()), 'missing implementer identity')
    review=record['independent_review']
    require(set(review)=={'status','independent','reviewer','scope','execution_manifest_sha256',
                         'policy_manifest_sha256','unresolved_executable_defects','report','executed_validation'},
            'malformed independent functional review')
    require(review['status']=='functional_approved_with_open_notes' and review['independent'] is True,
            'independent functional review pending')
    require(isinstance(review['reviewer'],str) and bool(review['reviewer'].strip()), 'missing actual reviewer identity')
    require(review['reviewer'].strip()!=implementer.strip(), 'self-review is forbidden')
    require(review['scope']==SCOPE, 'wrong independent review scope')
    require(review['unresolved_executable_defects']==[], 'unresolved executable defects')
    require(review['execution_manifest_sha256']==sha256(manifest), 'review does not cover current executed inputs')
    require(review['policy_manifest_sha256']==sha256(policy_manifest), 'review does not cover current acceptance policy')
    verify_artifact(review['report'],ROOT)
    original=read_json(verify_artifact(review['executed_validation'],ROOT))
    require(original['validation']=='PASS' and result['validation']=='PASS', 'execution validation failed')
    for key in ('execution_manifest_sha256','policy_manifest_sha256','physical'):
        require(original[key]==result[key], 'reviewed execution does not match current validated source/policy/result')
    require(result['execution_manifest_sha256']==sha256(manifest)
            and result['policy_manifest_sha256']==sha256(policy_manifest), 'stale execution result')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record',type=Path,default=ROOT/'docs/phase7_completion.json')
    parser.add_argument('--receipt',type=Path,required=True)
    args=parser.parse_args()
    from tools.phase7_validation_receipt import verify
    result=verify(args.receipt)
    build=args.receipt.resolve().parent
    check(args.record,build/'inputs.json',build/'policy-inputs.json',result)
    print('PHASE7_DEVELOPMENT_VALIDATION_PASS: independently approved functional scope; five evidence notes remain open')


if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyError,TypeError) as error:
        raise SystemExit('PHASE7_COMPLETION_PENDING: '+str(error))
