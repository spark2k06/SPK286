"""Valid functional fixtures ensure each negative reaches its rejection boundary."""
import copy,json,shutil,subprocess,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from tools import phase7_completion,phase7_policy
from tools.phase7_policy import sha256
from tools.phase7_completion import check


class CompletionTests(unittest.TestCase):
    def fixture(self,root):
        # Preserve the exact authorized notes. Reviewer/result objects below are
        # explicitly synthetic fixtures and never actual approval.
        for name in phase7_policy.snapshot():
            destination=root/name;destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(phase7_policy.ROOT/name,destination)
        manifest=root/'inputs.json';manifest.write_text('{"synthetic-executable":"fixture"}\n')
        policy=root/'policy.json';policy.write_text(json.dumps(phase7_policy.snapshot(root=root),sort_keys=True))
        artifact=root/'synthetic-review.txt';artifact.write_text('SYNTHETIC UNIT FIXTURE ONLY; no actual approval.\n')
        result=dict(validation='PASS',execution_manifest_sha256=sha256(manifest),policy_manifest_sha256=sha256(policy),physical={'synthetic':'fixture'})
        validation=root/'synthetic-result.json';validation.write_text(json.dumps(result))
        item=lambda p:dict(path=p.name,sha256=sha256(p))
        valid=dict(schema_version=2,implementer='SYNTHETIC IMPLEMENTER',independent_review={
            'status':'functional_approved_with_open_notes','independent':True,
            'reviewer':'SYNTHETIC INDEPENDENT REVIEWER','scope':phase7_completion.SCOPE,
            'execution_manifest_sha256':sha256(manifest),'policy_manifest_sha256':sha256(policy),
            'unresolved_executable_defects':[],'report':item(artifact),'executed_validation':item(validation)})
        record=root/'record.json';record.write_text(json.dumps(valid))
        return manifest,policy,result,valid,record

    def test_review_and_evidence_identity_checks_are_reached(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);manifest,policy,result,valid,record=self.fixture(root)
            with patch.object(phase7_completion,'ROOT',root):
                check(record,manifest,policy,result)
                for key,value,reason in [
                    ('status','pending','independent functional review pending'),
                    ('independent',False,'independent functional review pending'),
                    ('reviewer',' ','missing actual reviewer identity'),
                    ('reviewer',valid['implementer'],'self-review'),
                    ('scope','architectural-release','wrong independent review scope'),
                    ('unresolved_executable_defects',['real RTL fault'],'unresolved executable defects'),
                    ('execution_manifest_sha256','0'*64,'current executed inputs'),
                    ('policy_manifest_sha256','0'*64,'current acceptance policy'),
                    ('report',{'path':'synthetic-review.txt','sha256':'0'*64},'changed evidence artifact'),
                    ('report',{'path':'absent.txt','sha256':'0'*64},'missing or out-of-repository'),
                    ('report',{'path':'../outside.txt','sha256':'0'*64},'missing or out-of-repository')]:
                    changed=copy.deepcopy(valid);changed['independent_review'][key]=value
                    record.write_text(json.dumps(changed))
                    with self.subTest(key=key,value=value),self.assertRaisesRegex(ValueError,reason):
                        check(record,manifest,policy,result)
                record.write_text(json.dumps(valid))
                with self.assertRaisesRegex(ValueError,'execution validation failed'):
                    check(record,manifest,policy,dict(result,validation='FAIL'))
                with self.assertRaisesRegex(ValueError,'reviewed execution does not match'):
                    check(record,manifest,policy,dict(result,physical={'failed':1}))
                manifest.write_text('{"changed":true}')
                with self.assertRaisesRegex(ValueError,'current executed inputs'):
                    check(record,manifest,policy,result)

    def test_notes_and_changed_policy_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);manifest,policy,result,valid,record=self.fixture(root)
            notes_path=root/'docs/phase7_evidence_notes.json';original=json.loads(notes_path.read_text())
            with patch.object(phase7_completion,'ROOT',root):
                check(record,manifest,policy,result)
                for variant in ('duplicate','unknown','missing','resolved','bad-artifact','policy-edit'):
                    changed=copy.deepcopy(original)
                    if variant=='duplicate':changed['notes'][1]=copy.deepcopy(changed['notes'][0])
                    if variant=='unknown':changed['notes'][0]['id']='waived-new-behavior'
                    if variant=='missing':changed['notes'].pop()
                    if variant=='resolved':changed['notes'][0]['status']='resolved'
                    if variant=='bad-artifact':changed['notes'][0]['evidence'][0]['sha256']='0'*64
                    if variant=='policy-edit':changed['notes'][3]['selected_policy']='changed semantics'
                    notes_path.write_text(json.dumps(changed))
                    reason={'resolved':'unauthorized evidence status','bad-artifact':'changed evidence artifact','policy-edit':'acceptance-policy inputs changed'}.get(variant,'unknown, duplicate or missing')
                    with self.subTest(variant=variant),self.assertRaisesRegex(ValueError,reason):
                        check(record,manifest,policy,result)
                notes_path.write_text(json.dumps(original))
                # Restore byte identity, then alter one independently hashed policy artifact.
                shutil.copyfile(phase7_policy.ROOT/'docs/phase7_evidence_notes.json',notes_path)
                (root/'docs/PHASE7_FUNCTIONAL_POLICY.md').write_text('changed acceptance')
                with self.assertRaisesRegex(ValueError,'changed evidence artifact'):
                    check(record,manifest,policy,result)

    def test_remaining_increment_entrypoints_resolve(self):
        for target in ('phase7-arithmetic-check','phase7-string-check','phase7-io-check','phase7-check','phase7-exec-check'):
            with self.subTest(target=target):
                result=subprocess.run(['make','--dry-run',target],capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('scripts/validate_phase7_',result.stdout)
