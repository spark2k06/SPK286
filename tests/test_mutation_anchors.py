# SPDX-License-Identifier: MIT
"""Reject stale mutation definitions before the long dual-simulator gate."""
import importlib
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class MutationAnchorTests(unittest.TestCase):
    def test_null_ldtr_mutation_anchors(self):
        for label,module,old,new in importlib.import_module('tools.audit_null_ldtr').PROBES:
            with self.subTest(mutation=label):
                self.assertEqual((ROOT/'rtl'/(module+'.sv')).read_text().count(old),1)
                self.assertNotEqual(old,new)

    def test_task_publication_mutation_anchors(self):
        for label,module,old,new in importlib.import_module('tools.audit_task_late').PROBES:
            with self.subTest(mutation=label):
                self.assertEqual((ROOT/'rtl'/(module+'.sv')).read_text().count(old),1)
                self.assertNotEqual(old,new)

    def test_each_fault_can_be_injected_once_into_current_rtl(self):
        for name in ('audit_operand_boundaries', 'audit_alu',
                     'audit_stack_control', 'audit_events', 'audit_double_fault', 'audit_byte_prefix', 'audit_scalar', 'audit_shift', 'audit_data', 'audit_unary', 'audit_adjust', 'audit_segment', 'audit_stack_frame', 'audit_far', 'audit_strings', 'audit_io', 'audit_muldiv'):
            for label, module, bench, old, new, reason in importlib.import_module('tools.' + name).PROBES:
                with self.subTest(audit=name, mutation=label):
                    source = (ROOT / 'rtl' / (module + '.sv')).read_text()
                    olds = old if isinstance(old, tuple) else (old,)
                    news = new if isinstance(new, tuple) else (new,)
                    self.assertEqual(len(olds), len(news), 'unpaired mutation anchors')
                    for old_text, new_text in zip(olds, news):
                        self.assertEqual(source.count(old_text), 1, 'stale or ambiguous mutation anchor')
                        self.assertNotEqual(old_text, new_text, 'mutation must change the source')
                        source = source.replace(old_text, new_text)
                    self.assertTrue(reason, 'an intended semantic failure is required')
                    self.assertTrue((ROOT / 'sim/unit' / (bench + '_tb.sv')).is_file())


if __name__ == '__main__':
    unittest.main()
