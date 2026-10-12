# SPDX-License-Identifier: MIT
"""Aggregation of Yosys Cyclone V statistics into per-module resources."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('resource_report', ROOT / 'scripts/resource_report.py')
resource_report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(resource_report)


def stat(design_ffs=9):
    return {
        'modules': {
            '\\top': {'num_cells_by_type': {'MISTRAL_FF': 3, 'leaf': 2,
                                             '$paramod\\rom\\DEPTH=8': 1}},
            '\\leaf': {'num_cells_by_type': {'MISTRAL_ALUT6': 4, 'MISTRAL_NOT': 1,
                                              'MISTRAL_ALUT_ARITH': 2, 'MISTRAL_FF': 3}},
            '$paramod\\rom\\DEPTH=8': {'num_cells_by_type': {'MISTRAL_M10K': 1}},
        },
        'design': {'num_cells_by_type': {'MISTRAL_FF': design_ffs, 'MISTRAL_ALUT6': 8,
                                         'MISTRAL_NOT': 2, 'MISTRAL_ALUT_ARITH': 4,
                                         'MISTRAL_M10K': 1}},
    }


class ResourceReportTests(unittest.TestCase):
    def test_instances_multiply_module_resources(self):
        per_module, total = resource_report.summarize(stat(), 'top')
        self.assertEqual(per_module['leaf']['instances'], 2)
        self.assertEqual(per_module['leaf']['luts'], 10)
        self.assertEqual(per_module['rom']['m10k'], 1)
        self.assertEqual(total, {'luts': 10, 'arith': 4, 'ffs': 9, 'm10k': 1, 'mlab': 0, 'dsp': 0})

    def test_mismatched_design_total_fails(self):
        with self.assertRaises(ValueError):
            resource_report.summarize(stat(design_ffs=10), 'top')

    def test_unknown_cell_type_fails(self):
        data = stat()
        data['modules']['\\leaf']['num_cells_by_type']['$_AND_'] = 1
        with self.assertRaises(ValueError):
            resource_report.summarize(data, 'top')

    def test_markdown_lists_instances_and_total(self):
        per_module, total = resource_report.summarize(stat(), 'top')
        table = resource_report.markdown(per_module, total, 'top')
        self.assertIn('`leaf` (x2) | 10 | 4 | 6 | 0 | 0 | 0 |', table)
        self.assertIn('**Total `top`**', table)

    def test_wrapper_ties_every_non_functional_port(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            text = resource_report.wrapper('spk286', Path(directory) / 'w.sv').read_text()
        ports = resource_report.ports(ROOT / 'rtl/spk286.sv', 'spk286')
        self.assertEqual(text.count('\n        .'), len(ports))
        self.assertIn(".execute_enable('1)", text)
        self.assertIn(".redirect('0)", text)
        self.assertIn('.bus_status(bus_status)', text)
        self.assertIn('.debug_ip()', text)


if __name__ == '__main__':
    unittest.main()
