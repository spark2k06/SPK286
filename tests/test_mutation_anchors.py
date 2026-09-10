"""Reject stale mutation definitions before the long dual-simulator gate."""
import importlib
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class MutationAnchorTests(unittest.TestCase):
    def test_each_fault_can_be_injected_once_into_current_rtl(self):
        for name in ('audit_phase3_boundaries', 'audit_alu',
                     'audit_stack_control', 'audit_events', 'audit_byte_prefix', 'audit_scalar', 'audit_shift', 'audit_data', 'audit_unary', 'audit_adjust', 'audit_segment', 'audit_stack_frame', 'audit_far', 'audit_strings', 'audit_io', 'audit_muldiv'):
            for label, module, bench, old, new, reason in importlib.import_module('tools.' + name).PROBES:
                with self.subTest(audit=name, mutation=label):
                    source = (ROOT / 'rtl' / (module + '.sv')).read_text()
                    self.assertEqual(source.count(old), 1, 'stale or ambiguous mutation anchor')
                    self.assertNotEqual(old, new, 'mutation must change the source')
                    self.assertTrue(reason, 'an intended semantic failure is required')
                    self.assertTrue((ROOT / 'sim/unit' / (bench + '_tb.sv')).is_file())


if __name__ == '__main__':
    unittest.main()
