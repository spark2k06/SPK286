"""Phase 3 strict admission and visible/disjoint scope accounting."""
import argparse
import contextlib
from copy import deepcopy
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from tools.run_singlestep import prepare_case, scope_exclusion, run_opcode, SingleStepRunnerError
from tools.singlestep import SingleStepCase
from test_singlestep_runner import REGS

def mapping(opcode=0x8B, modrm=0xC3, displacement=(), index=0):
    data = [opcode, modrm, *displacement, 0xF4]
    return {"idx": index, "name": "synthetic MOV admission", "bytes": data,
            "initial": {"regs": dict(REGS), "ram": [[0x11200+i,b] for i,b in enumerate(data)]},
            "final": {"regs": {"ip": 0x1200+len(data)}}, "hash": f"{index:040x}"}

class OperandAdmissionTests(unittest.TestCase):
    def test_lengths_and_halt_boundary_for_every_modrm(self):
        for opcode in (0x89, 0x8B):
            for encoded in range(256):
                mode, rm = encoded >> 6, encoded & 7
                count = 1 if mode == 1 else (2 if mode == 2 or mode == 0 and rm == 6 else 0)
                value = mapping(opcode, encoded, [0xA5]*count)
                prepared = prepare_case(SingleStepCase.from_mapping(value), f"{opcode:02X}")
                self.assertEqual(prepared.expected_regs[12], 0x1202+count)
                self.assertEqual(dict(prepared.initial_ram), dict(prepared.expected_ram))
                for bad in (value["bytes"][:-2]+[0xF4], value["bytes"][:-1]+[0x90,0xF4]):
                    damaged = deepcopy(value); damaged["bytes"] = bad
                    with self.assertRaises(SingleStepRunnerError):
                        prepare_case(SingleStepCase.from_mapping(damaged), f"{opcode:02X}")

    def test_exclusions_are_explicit_and_never_prepared_as_passes(self):
        for prefixes in ([0x26], [0x2E,0x36,0x3E], [0xF0], [0xF3]):
            value = mapping(); value["bytes"] = prefixes + value["bytes"]
            case = SingleStepCase.from_mapping(value)
            self.assertEqual(scope_exclusion(case, "8B"), "unsupported_prefix")
            with self.assertRaises(SingleStepRunnerError): prepare_case(case, "8B")
        value = mapping(); value["exception"] = {"number": 13, "flag_address": 0x20000}
        case = SingleStepCase.from_mapping(value)
        self.assertEqual(scope_exclusion(case, "8B"), "exception_delivery")
        with self.assertRaises(SingleStepRunnerError): prepare_case(case, "8B")
        for prefix in (0x66, 0x67, 0x64, 0x65, 0x90):
            value = mapping(); value["bytes"].insert(0,prefix)
            with self.assertRaises(SingleStepRunnerError): scope_exclusion(SingleStepCase.from_mapping(value), "8B")

    def test_scope_selection_revocation_and_execution_are_disjoint(self):
        values = [mapping(index=i) for i in range(7)]
        values[1]["bytes"].insert(0,0x26)
        values[2]["exception"] = {"number":13,"flag_address":0x20000}
        values[3]["bytes"].insert(0,0xF0) # Revocation wins over scope classification.
        cases = tuple(SingleStepCase.from_mapping(v) for v in values)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); (root/"v1_real_mode").mkdir(); (root/"v1_real_mode/8B.MOO.gz").touch()
            args = argparse.Namespace(sample=2, full=False, index=None, test_hash=None, trace=None)
            with patch("tools.run_singlestep.load_source", return_value=cases), \
                 patch("tools.run_singlestep.subprocess.run", return_value=subprocess.CompletedProcess([],0,
                     "SINGLESTEP_RESULT executed=2 passed=2 failed=0\n", "")), contextlib.redirect_stdout(io.StringIO()):
                result = run_opcode("8B", root, frozenset({cases[3].test_hash}), args, root, root/"sim")
                self.assertEqual(result,(7,1,1,1,2,2,2,0))
                report = json.loads((root/"singlestep/reports/8B.json").read_text())
                self.assertEqual(report["selected"],2)
                self.assertEqual([e["index"] for e in report["exclusions"]],[1,2])
                args.index = 1
                with self.assertRaisesRegex(SingleStepRunnerError,"requested case excluded"):
                    run_opcode("8B", root, frozenset(), args, root, root/"sim")
