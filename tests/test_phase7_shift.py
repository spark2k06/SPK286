"""Shift gate rejects incomplete dependencies and corrupt/overlapping identities."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from tools.phase7_shift_reports import validate_identities


class ShiftReportTests(unittest.TestCase):
    def test_identity_failures_are_not_hidden_by_passing_counters(self):
        good = [{'index':i, 'hash':f'{i:040x}', 'category':'new_form'} for i in range(2)]
        def check(rows, seen=None, digest=None):
            raw = json.dumps(rows).encode()
            report = {'opcode':'D2.4', 'identity_sha256':digest or hashlib.sha256(raw).hexdigest()}
            validate_identities(raw, report, 2, set() if seen is None else seen)
        check(good)
        for key, values in {'index':(True, -1, 2, 0), 'hash':('', 'x'*40, '0'*40), 'category':('inherited', '')}.items():
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    bad = copy.deepcopy(good); bad[1][key] = value; check(bad)
        for rows in (good[:1], good+[good[0]], {}, [None, good[1]]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                check(rows)
        with self.assertRaises(ValueError): check(good, seen={'0'*40})
        with self.assertRaises(ValueError): check(good, digest='0'*64)
        for key in good[0]:
            with self.subTest(missing=key), self.assertRaises(ValueError):
                bad = copy.deepcopy(good); del bad[0][key]; check(bad)

    def test_shift_gate_propagates_first_dependency_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); binary = root/'bin'; binary.mkdir(); stub = binary/'python3'
            stub.write_text('#!/bin/sh\nexit 23\n'); stub.chmod(0o755)
            env = dict(os.environ, PATH=str(binary)+os.pathsep+os.environ['PATH'], SPK286_BUILD_DIR=str(root/'fresh'))
            result = subprocess.run(['bash', 'scripts/validate_phase7_shift.sh'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 23)
            self.assertIn('stage=inputs status=23', result.stderr)
            self.assertNotIn('VALIDATION_PASS', result.stdout+result.stderr)
            self.assertFalse((root/'fresh/scalar').exists())
