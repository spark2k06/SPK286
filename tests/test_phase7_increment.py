import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from tools.phase7_scope import require_complete
from tools.phase7_reports import summarize

class Phase7IncrementTests(unittest.TestCase):
    def test_clean_fetch_includes_every_active_corpus_family(self):
        from tools.fetch_singlestep import REQUIRED_PATHS
        from tools.run_singlestep import SUPPORTED_OPCODES
        requested = {p for p in REQUIRED_PATHS if p.endswith('.MOO.gz')}
        self.assertEqual(requested, {'/v1_real_mode/' + op + '.MOO.gz'
                                     for op in SUPPORTED_OPCODES})
        self.assertEqual(len(REQUIRED_PATHS), len(set(REQUIRED_PATHS)))

    def test_complete_phase_cannot_pass_as_a_subset(self):
        from unittest.mock import patch
        from tools.run_singlestep import SUPPORTED_OPCODES, MULDIV_OPCODES
        with patch('tools.phase7_scope.SUPPORTED_OPCODES', tuple(op for op in SUPPORTED_OPCODES if op not in MULDIV_OPCODES)):
            with self.assertRaisesRegex(ValueError,'10 required opcode families remain unimplemented'):
                require_complete()
        require_complete()


    def test_missing_reports_and_malformed_inventory_are_errors(self):
        with tempfile.TemporaryDirectory() as d:
            directory=Path(d)
            with self.assertRaisesRegex(ValueError,'missing/extra'):
                summarize(directory)
            source=json.loads(Path('docs/phase7_forms.json').read_text())
            source['forms'].pop()
            manifest=directory/'forms.json';manifest.write_text(json.dumps(source))
            with self.assertRaisesRegex(ValueError,'inventory'):
                summarize(directory,manifest)

    def test_increment_gate_propagates_input_capture_failure(self):
        # Execute the real shell composition with a failed first dependency.
        # No expensive simulator is necessary to prove a failed input capture
        # cannot reach a success marker or create an inherited output tree.
        with tempfile.TemporaryDirectory() as d:
            import os
            root=Path(d);binary=root/'bin';binary.mkdir();stub=binary/'python3'
            stub.write_text('#!/bin/sh\nexit 23\n');stub.chmod(0o755)
            env=dict(os.environ,PATH=str(binary)+os.pathsep+os.environ['PATH'],SPK286_BUILD_DIR=str(root/'fresh'))
            result=subprocess.run(['bash','scripts/validate_phase7_byte_prefix.sh'],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,23)
            self.assertIn('stage=inputs status=23',result.stderr)
            self.assertNotIn('VALIDATION_PASS',result.stdout+result.stderr)
            self.assertFalse((root/'fresh/phase6').exists())
