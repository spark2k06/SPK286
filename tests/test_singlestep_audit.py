"""Adversarial checks for corpus admission and simulator result accounting."""

import argparse
import contextlib
from copy import deepcopy
import io
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tools.run_singlestep import SingleStepRunnerError, prepare_case, run_opcode, select_cases
from tools.singlestep import SingleStepCase, SingleStepFormatError, load_moo
from tools.audit_singlestep import independent_wire_masks, compare_final_state
from test_singlestep import chunk, regs
from test_singlestep_runner import REGS


def case_mapping():
    return {
        "idx": 0, "name": "mov ax,1234h", "bytes": [0xB8, 0x34, 0x12, 0xF4],
        "initial": {"regs": dict(REGS),
                    "ram": [[0x11200 + i, byte] for i, byte in enumerate([0xB8, 0x34, 0x12, 0xF4])]},
        "final": {"regs": {"ax": 0x1234, "ip": 0x1204}},
        "hash": "ab" * 20,
    }


class SingleStepAdmissionTests(unittest.TestCase):
    def test_exception_is_not_silently_ignored(self):
        value = case_mapping()
        value["exception"] = {"number": 13, "flag_address": 0x20000}
        with self.assertRaisesRegex(SingleStepRunnerError, "exception"):
            prepare_case(SingleStepCase.from_mapping(value), "B8")

    def test_declared_instruction_bytes_must_match_initialized_memory(self):
        for variant in ("missing", "different"):
            with self.subTest(variant=variant):
                value = case_mapping()
                if variant == "missing":
                    value["initial"]["ram"].pop(1)
                else:
                    value["initial"]["ram"][1][1] ^= 1
                with self.assertRaisesRegex(SingleStepRunnerError, "instruction.*RAM|RAM.*instruction"):
                    prepare_case(SingleStepCase.from_mapping(value), "B8")

    def test_unsupported_prefixes_are_errors_not_passes(self):
        for prefixes in ([0x26], [0x2E, 0x36, 0x3E], [0xF0], [0xF2], [0xF3], [0x26, 0xF0, 0xF3]):
            with self.subTest(prefixes=prefixes):
                value = case_mapping()
                value["bytes"] = prefixes + value["bytes"]
                value["final"]["regs"]["ip"] += len(prefixes)
                with self.assertRaises(SingleStepRunnerError):
                    prepare_case(SingleStepCase.from_mapping(value), "B8")

    def test_unsupported_length_is_rejected_before_simulation(self):
        value = case_mapping()
        value["bytes"].insert(-1, 0x90)
        value["final"]["regs"]["ip"] += 1
        with self.assertRaisesRegex(SingleStepRunnerError, "length|four bytes"):
            prepare_case(SingleStepCase.from_mapping(value), "B8")

    def test_unrepresentable_initial_flags_are_rejected(self):
        value = case_mapping()
        value["initial"]["regs"]["flags"] |= 0x8000
        value["final"]["reg_masks"] = {"flags": 0}
        with self.assertRaisesRegex(SingleStepRunnerError, "FLAGS|flags"):
            prepare_case(SingleStepCase.from_mapping(value), "B8")

    def test_nonempty_queues_and_unknown_state_are_rejected(self):
        for side, key, data in (("initial", "queue", [1]), ("final", "queue", [1]),
                                ("initial", "msw", 1), ("final", "msw", 1)):
            value = case_mapping()
            value[side][key] = data
            with self.subTest(side=side, key=key), self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(value), "B8")


class SingleStepAccountingTests(unittest.TestCase):
    def invoke(self, stdout, returncode=0, cases=None):
        case = SingleStepCase.from_mapping(case_mapping())
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "v1_real_mode").mkdir()
            (root / "v1_real_mode/B8.MOO.gz").touch()
            args = argparse.Namespace(sample=None, full=True, index=None, test_hash=None, trace=None)
            with patch("tools.run_singlestep.load_source", return_value=tuple(cases or [case])), \
                 patch("tools.run_singlestep.subprocess.run", return_value=subprocess.CompletedProcess(
                     [], returncode, stdout, "")), contextlib.redirect_stdout(io.StringIO()):
                return run_opcode("B8", root, frozenset(), args, root, root / "simulator")

    def test_incomplete_or_inconsistent_result_is_an_error(self):
        for stdout, status in (
            ("SINGLESTEP_RESULT executed=0 passed=0 failed=0\n", 0),
            ("SINGLESTEP_RESULT executed=1 passed=0 failed=0\n", 0),
            ("SINGLESTEP_RESULT executed=1 passed=1 failed=0\n", 1),
            ("SINGLESTEP_RESULT executed=1 passed=0 failed=1\n", 0),
            ("SINGLESTEP_RESULT executed=1 passed=1 failed=0\n" * 2, 0),
            ("SINGLESTEP_RESULT executed=1 passed=1 failed=0\nSINGLESTEP_RESULT broken\n", 0),
            ("SINGLESTEP_RESULT executed=1 passed=1 failed=0\n", 2),
            ("", 0),
        ):
            with self.subTest(stdout=stdout, status=status), self.assertRaises(SingleStepRunnerError):
                self.invoke(stdout, status)

    def test_positive_and_negative_results_keep_exact_totals(self):
        self.assertEqual(self.invoke("SINGLESTEP_RESULT executed=1 passed=1 failed=0 cycles=10\n"),
                         (1, 0, 0, 0, 0, 1, 1, 0))
        self.assertEqual(self.invoke("SINGLESTEP_RESULT executed=1 passed=0 failed=1 cycles=10\n", 1),
                         (1, 0, 0, 0, 0, 1, 0, 1))

    def test_duplicate_case_identity_is_not_double_counted(self):
        first = case_mapping()
        for key in ("idx", "hash"):
            second = deepcopy(first)
            second["idx"] = 1
            second["hash"] = "cd" * 20
            second[key] = first[key]
            cases = [SingleStepCase.from_mapping(value) for value in (first, second)]
            with self.subTest(key=key), self.assertRaisesRegex(SingleStepRunnerError, "duplicate"):
                self.invoke("SINGLESTEP_RESULT executed=2 passed=2 failed=0\n", cases=cases)

    def test_revocations_and_sampling_are_disjoint_from_executions(self):
        cases = []
        for index in range(5):
            value = case_mapping()
            value["idx"] = index
            value["hash"] = f"{index:040x}"
            cases.append(SingleStepCase.from_mapping(value))
        revoked = frozenset({cases[1].test_hash})
        selected, skipped = select_cases(tuple(cases), revoked, 2, False, None, None)
        self.assertEqual([case.index for case in selected], [0, 2])
        self.assertEqual(len(cases), 1 + skipped + len(selected))
        selected, skipped = select_cases(tuple(cases), revoked, None, True, None, None)
        self.assertEqual([case.index for case in selected], [0, 2, 3, 4])
        self.assertEqual(skipped, 0)
        for index, test_hash in ((1, None), (None, cases[1].test_hash)):
            with self.assertRaisesRegex(SingleStepRunnerError, "non-revoked"):
                select_cases(tuple(cases), revoked, None, False, index, test_hash)


class MooIntegrityTests(unittest.TestCase):
    def test_independent_common_and_per_case_wire_masks(self):
        common = chunk('RMSK', regs([0xf7ee], 1 << 13))
        test0 = chunk('TEST', struct.pack('<I', 0) + chunk('FINA', b''))
        test1 = chunk('TEST', struct.pack('<I', 1) + chunk('FINA',
                      chunk('RMSK', regs([0x00ff, 0x7fff], (1 << 0) | (1 << 13)))))
        self.assertEqual(independent_wire_masks(common + test0 + test1),
                         {0: {'flags': 0xf7ee}, 1: {'flags': 0x77ee, 'ax': 0x00ff}})
        self.assertEqual(independent_wire_masks(test0), {0: {}})

    def test_mask_audit_rejects_missing_changed_and_extra_state(self):
        upstream = {'regs': {'flags': 0x486}, 'ram': [], 'queue': []}
        actual = {**upstream, 'reg_masks': {'flags': 0xf7ee}}
        compare_final_state(actual, upstream, {'flags': 0xf7ee})
        for bad in (upstream, {**actual, 'reg_masks': {'flags': 0xffff}},
                    {**actual, 'reg_masks': {'flags': 0xf7ee, 'ax': 0}},
                    {**actual, 'regs': {'flags': 0x482}}, {**actual, 'unexpected': 1}):
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                compare_final_state(bad, upstream, {'flags': 0xf7ee})

    def test_mask_wire_audit_rejects_truncation_and_invalid_presence(self):
        for data in (b'RMSK', b'RMSK\x04\0\0\0\x00', chunk('RMSK', b'\0'),
                     chunk('RMSK', regs([], 1 << 13)), chunk('RMSK', regs([1], 1 << 14))):
            with self.subTest(data=data), self.assertRaises(RuntimeError):
                independent_wire_masks(data)

    def test_header_count_version_and_cpu_are_validated(self):
        test = chunk("TEST", struct.pack("<I", 0))
        for version, count, cpu in (([2, 0], 1, b"C286"), ([1, 2], 1, b"C286"),
                                    ([1, 1], 2, b"C286"), ([1, 1], 1, b"C386")):
            data = chunk("MOO ", bytes(version + [0, 0]) + struct.pack("<I", count) + cpu) + test
            with tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / "bad.moo"
                path.write_bytes(data)
                with self.subTest(version=version, count=count, cpu=cpu), self.assertRaises(SingleStepFormatError):
                    load_moo(path)

    def test_duplicate_header_and_state_chunks_are_rejected(self):
        header = chunk("MOO ", bytes([1, 1, 0, 0]) + struct.pack("<I", 1) + b"C286")
        state = chunk("REGS", regs([1], 1))
        for data in (header + header + chunk("TEST", struct.pack("<I", 0)),
                     header + chunk("TEST", struct.pack("<I", 0) + chunk("INIT", state + state))):
            with tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / "bad.moo"
                path.write_bytes(data)
                with self.assertRaises(SingleStepFormatError):
                    load_moo(path)


if __name__ == "__main__":
    unittest.main()
