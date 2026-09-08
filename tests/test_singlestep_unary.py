"""Exact unary encodings, memory preservation and gate failure propagation."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from tests.test_singlestep_byte_prefix import vector
from tools.singlestep import SingleStepCase
from tools.run_singlestep import prepare_case, scope_exclusion, SingleStepRunnerError


class UnaryAdmissionTests(unittest.TestCase):
    def test_all_unary_forms_preserve_bytes_without_immediate(self):
        for op, extension in ((0xf6,2),(0xf6,3),(0xf7,2),(0xf7,3),(0xfe,0),(0xfe,1),(0xff,0),(0xff,1)):
            name = f'{op:02X}.{extension}'
            for mode in range(4):
                for prefix in ([],[0xf2,0x36],[0xf0,0x3e]):
                    code = prefix+[op,mode*64+extension*8+6]+([0x80] if mode==1 else [1,0x10] if mode in (0,2) else [])+[0xf4]
                    case = SingleStepCase.from_mapping(vector(code,name))
                    self.assertIsNone(scope_exclusion(case,name,True,True))
                    prepared = prepare_case(case,name,True,True)
                    self.assertEqual(prepared.source.instruction_bytes,tuple(code))
                    self.assertEqual(prepared.initial_ram,prepared.expected_ram)
                    self.assertEqual(len(prepared.initial_ram),len(code))

    def test_unary_rejects_group_mismatch_missing_displacement_and_extra_immediate(self):
        for name,code in [('F7.2',[0xf7,0xd8,0xf4]),('FF.0',[0xff,6,1,0xf4]),
                          ('FE.1',[0xfe,0xc8,1,0xf4]),('F6.3',[0xf6,0xd8,1,0xf4]),
                          ('F7.3',[0xf7,0xd8,1,2,0xf4])]:
            with self.subTest(code=code),self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(vector(code,name)),name,True,True)

    def test_unary_gate_stops_at_first_failed_dependency(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); binary = root/'bin'; binary.mkdir(); stub = binary/'python3'
            stub.write_text('#!/bin/sh\nexit 23\n'); stub.chmod(0o755)
            env = dict(os.environ, PATH=str(binary)+os.pathsep+os.environ['PATH'], SPK286_BUILD_DIR=str(root/'fresh'))
            result = subprocess.run(['bash', 'scripts/validate_phase7_unary.sh'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 23)
            self.assertIn('stage=inputs status=23', result.stderr)
            self.assertNotIn('VALIDATION_PASS', result.stdout+result.stderr)
            self.assertFalse((root/'fresh/data').exists())
