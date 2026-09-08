"""Malformed, incomplete or skipped scalar results cannot satisfy the increment."""
import copy
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from tools.phase7_scalar_reports import validate_report


class ScalarReportTests(unittest.TestCase):
    def test_counter_failures_source_changes_and_missing_fields_rejected(self):
        form = {'case_count':5000,'git_blob':'a'*40}
        report = {'opcode':'F7.0','discovered':5000,'selected':5000,'executed':5000,'passed':5000,
                  'revoked':0,'prefix_skipped':0,'exception_skipped':0,'selection_skipped':0,'failed':0,
                  'source_git_blob':'a'*40}
        self.assertEqual(validate_report(report,'F7.0',form),5000)
        for key in report:
            with self.subTest(missing=key), self.assertRaises(ValueError):
                bad=copy.deepcopy(report);del bad[key];validate_report(bad,'F7.0',form)
        for key in ('discovered','selected','executed','passed','revoked','prefix_skipped','exception_skipped','selection_skipped','failed'):
            for value in (-1,True,1.0,'0',report[key]+1):
                with self.subTest(key=key,value=value), self.assertRaises(ValueError):
                    bad=copy.deepcopy(report);bad[key]=value;validate_report(bad,'F7.0',form)
        for key in ('opcode','source_git_blob'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                bad=copy.deepcopy(report);bad[key]='changed';validate_report(bad,'F7.0',form)

    def test_scalar_gate_propagates_first_dependency_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);binary=root/'bin';binary.mkdir();stub=binary/'python3'
            stub.write_text('#!/bin/sh\nexit 23\n');stub.chmod(0o755)
            env=dict(os.environ,PATH=str(binary)+os.pathsep+os.environ['PATH'],SPK286_BUILD_DIR=str(root/'fresh'))
            result=subprocess.run(['bash','scripts/validate_phase7_scalar.sh'],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,23)
            self.assertIn('stage=inputs status=23',result.stderr)
            self.assertNotIn('VALIDATION_PASS',result.stdout+result.stderr)
            self.assertFalse((root/'fresh/byte').exists())
