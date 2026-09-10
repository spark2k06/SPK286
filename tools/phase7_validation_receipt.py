"""Bind successful executable stages to their exact inputs and retained outputs."""
import argparse
import json
from pathlib import Path
from tools.phase6_inputs import snapshot as execution_snapshot
from tools.phase6_reports import require
from tools.phase7_policy import snapshot as policy_snapshot, read_json, sha256

STAGES = ('inherited-executable', 'complete-physical', 'phase7-mutations',
          'arithmetic-and-port-comparators', 'consistency')


def result_summary(build):
    for stage in STAGES:
        lines=(build/'logs'/(stage+'.log')).read_text().splitlines()
        require(bool(lines) and lines[-1]=='PHASE7_STAGE_PASS '+stage
                and lines.count('PHASE7_STAGE_PASS '+stage)==1, 'missing completed executable stage: '+stage)
    physical = read_json(build / 'physical-summary.json')
    require(physical['validation'] == 'PASS' and physical['required_population'] == 1386997
            and physical['totals'] == {'discovered':1387000,'revoked':3,'executed':1386996,'passed':1386996,'failed':0}
            and physical['unexpected_omissions'] == 0, 'invalid complete physical result')
    from tools.phase7_capture_admission import CAPTURE
    require(physical['not_evaluable'] == [CAPTURE], 'invalid incomplete capture result')
    return dict(validation='PASS', execution_manifest_sha256=sha256(build/'inputs.json'),
                policy_manifest_sha256=sha256(build/'policy-inputs.json'), physical=physical)


def artifact_names(build):
    names={'inputs.json','policy-inputs.json','physical-summary.json','physical/summary.json'}
    names.update('logs/'+stage+'.log' for stage in STAGES)
    for directory in ('physical/singlestep/reports','physical/singlestep/identities','physical/family-logs'):
        paths=list((build/directory).glob('*'))
        require(len(paths)==307, 'incomplete receipt physical artifact inventory')
        names.update(p.relative_to(build).as_posix() for p in paths)
    # Bind retained evidence for unit/regression/synthesis, pristine controls,
    # every mutation/comparator and synthetic run, plus executed batches/binaries.
    # C++ compiler intermediates (.o/.a/generated .cpp/.h) are reproducible build
    # products, not evidence. The receipt itself cannot participate in its hash.
    evidence_suffixes={'.log','.json','.txt','.sha256','.bin','.vcd','.vvp','.sv','.svh','.py','.mc'}
    for path in build.rglob('*'):
        if not path.is_file() or '.git' in path.relative_to(build).parts:
            continue
        name=path.relative_to(build).as_posix()
        if name=='execution-receipt.json':
            continue
        if path.suffix in evidence_suffixes or path.name=='spk286_smoke' or (not path.suffix and path.name.endswith('_tb')):
            require(not path.is_symlink() and path.resolve().is_relative_to(build.resolve()), 'unsafe receipt artifact')
            names.add(name)
    return names


def verify(path):
    build=path.resolve().parent
    receipt=read_json(path)
    require(set(receipt)=={'schema_version','result','artifacts'}
            and type(receipt['schema_version']) is int and receipt['schema_version']==1,
            'malformed executable receipt')
    require(read_json(build/'inputs.json')==execution_snapshot(), 'executed source inputs changed')
    require(read_json(build/'policy-inputs.json')==policy_snapshot(), 'acceptance-policy inputs changed')
    require(set(receipt['artifacts'])==artifact_names(build), 'missing/extra executable receipt artifacts')
    for name,digest in receipt['artifacts'].items():
        require(sha256(build/name)==digest, 'changed executable result artifact: '+name)
    require(receipt['result']==result_summary(build), 'changed executable result summary')
    return receipt['result']


def create(build):
    require(read_json(build/'inputs.json')==execution_snapshot(), 'executed source inputs changed')
    require(read_json(build/'policy-inputs.json')==policy_snapshot(), 'acceptance-policy inputs changed')
    receipt=dict(schema_version=1,result=result_summary(build),
                 artifacts={name:sha256(build/name) for name in sorted(artifact_names(build))})
    path=build/'execution-receipt.json'
    require(not path.exists(), 'executable receipt already exists')
    path.write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
    verify(path)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir',type=Path)
    parser.add_argument('--verify',type=Path)
    args=parser.parse_args()
    require(bool(args.build_dir)^bool(args.verify), 'choose creation or verification')
    if args.verify:verify(args.verify)
    else:create(args.build_dir)
    print('PHASE7_EXECUTABLE_RECEIPT PASS: exact source, policy and retained execution artifacts')


if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyError,TypeError) as error:
        raise SystemExit('PHASE7_EXECUTABLE_RECEIPT FAIL: '+str(error))
