import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from tools.phase6_evidence import validate
from tools.event_streams import scenario


ROOT=Path(__file__).resolve().parents[1]


class Phase6ReleaseTests(unittest.TestCase):
    def test_unresolved_or_missing_evidence_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'evidence.json'
            path.write_text(json.dumps({'schema':1,'phase':6,'decisions':[{'id':name,'status':'unresolved'} for name in
                            ('failed-iret-nmi','sti-old-if','fault-tf')]}))
            with self.assertRaisesRegex(ValueError,'unresolved 286 evidence'):validate(path)
            for value in ({}, {'schema':1,'phase':6,'decisions':[]},
                          {'schema':1,'phase':6,'decisions':[{'id':name,'status':'resolved'} for name in
                           ('failed-iret-nmi','sti-old-if','fault-tf')]}):
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):validate(path)

    def test_dependent_stream_generation_is_reproducible(self):
        self.assertEqual(scenario(0),scenario(0))
        self.assertNotEqual(scenario(0),scenario(1))

    @unittest.skipUnless(shutil.which('bash'),'release shell requires bash')
    def test_nested_check_failure_propagates_without_success_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'scripts').mkdir();(root/'bin').mkdir()
            shutil.copy2(ROOT/'scripts/validate_phase6.sh',root/'scripts/validate_phase6.sh')
            for name,status in (('python3',0),('make',23)):
                path=root/'bin'/name;path.write_text(f'#!/bin/sh\nexit {status}\n');path.chmod(0o755)
            env={**os.environ,'PATH':str(root/'bin')+os.pathsep+os.environ['PATH'],
                 'SPK286_BUILD_DIR':str(root/'fresh')}
            result=subprocess.run(['bash',str(root/'scripts/validate_phase6.sh')],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,23,result.stdout+result.stderr)
            self.assertIn('PHASE6_VALIDATION_FAIL: stage=inherited status=23',result.stderr)
            self.assertNotIn('PHASE6_VALIDATION_PASS',result.stdout)
