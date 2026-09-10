"""Extra unit arguments must not silently reduce validation coverage."""
import subprocess
import unittest

class UnitSelectionTests(unittest.TestCase):
    def test_multiple_unit_arguments_are_rejected_before_running_any_bench(self):
        result=subprocess.run(['bash','scripts/test_units.sh','both','spk286_decoder','spk286_muldiv'],capture_output=True,text=True)
        self.assertEqual(result.returncode,2)
        self.assertIn('one unit name',result.stderr)
        self.assertNotIn('PASS',result.stdout+result.stderr)
