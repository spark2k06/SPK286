"""All-file diagnostics cannot turn independent failures into a green gate."""
import unittest
from tools.run_phase7_physical import run_all
from tools.run_singlestep import SingleStepRunnerError

class FullPhysicalTests(unittest.TestCase):
    def test_preparation_and_execution_failures_are_both_retained(self):
        visited=[]
        def execute(opcode):
            visited.append(opcode)
            if opcode=='bad_capture':raise SingleStepRunnerError('incomplete captured transfer')
            return (2,0,0,0,0,2,1,1) if opcode=='bad_cpu' else (2,0,0,0,0,2,2,0)
        result=run_all(('bad_capture','bad_cpu','valid'),execute)
        self.assertEqual(visited,['bad_capture','bad_cpu','valid'])
        self.assertEqual(result['validation'],'FAIL');self.assertEqual(len(result['errors']),2)
        self.assertEqual(result['totals']['executed'],4);self.assertEqual(result['totals']['failed'],1)
    def test_missing_execution_and_exclusions_are_never_passes(self):
        result=run_all(('excluded',),lambda _: (2,0,1,0,0,1,1,0))
        self.assertEqual(result['validation'],'FAIL')
        result=run_all(('malformed',),lambda _: (2,0,0))
        self.assertEqual(result['validation'],'FAIL')


class CompleteGateTests(unittest.TestCase):
    def test_input_failure_cannot_launch_the_inherited_gate(self):
        import os,subprocess,tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);binary=root/'bin';binary.mkdir();stub=binary/'python3'
            stub.write_text('#!/bin/sh\nexit 23\n');stub.chmod(0o755)
            env=dict(os.environ,PATH=str(binary)+os.pathsep+os.environ['PATH'],SPK286_BUILD_DIR=str(root/'fresh'))
            result=subprocess.run(['make','phase7-check'],env=env,capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0);self.assertIn('stage=inputs status=23',result.stderr)
            self.assertNotIn('PHASE7_DEVELOPMENT_VALIDATION_PASS',result.stdout+result.stderr)
            self.assertFalse((root/'fresh/phase6').exists())
