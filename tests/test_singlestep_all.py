# SPDX-License-Identifier: MIT
"""All-file diagnostics cannot turn independent failures into a green run."""
import unittest

from tools.run_singlestep import SingleStepRunnerError
from tools.run_singlestep_all import run_all


class FullCorpusTests(unittest.TestCase):
    def test_preparation_and_execution_failures_are_both_retained(self):
        visited = []

        def execute(opcode):
            visited.append(opcode)
            if opcode == 'bad_capture':
                raise SingleStepRunnerError('incomplete captured transfer')
            return (2, 0, 0, 0, 0, 2, 1, 1) if opcode == 'bad_cpu' else (2, 0, 0, 0, 0, 2, 2, 0)

        result = run_all(('bad_capture', 'bad_cpu', 'valid'), execute)
        self.assertEqual(visited, ['bad_capture', 'bad_cpu', 'valid'])
        self.assertEqual(result['validation'], 'FAIL')
        self.assertEqual(len(result['errors']), 2)
        self.assertEqual(result['totals']['executed'], 4)
        self.assertEqual(result['totals']['failed'], 1)

    def test_missing_execution_and_exclusions_are_never_passes(self):
        self.assertEqual(run_all(('excluded',), lambda _: (2, 0, 1, 0, 0, 1, 1, 0))['validation'], 'FAIL')
        self.assertEqual(run_all(('malformed',), lambda _: (2, 0, 0))['validation'], 'FAIL')

    def test_complete_run_passes(self):
        result = run_all(('a', 'b'), lambda _: (3, 1, 0, 0, 0, 2, 2, 0))
        self.assertEqual(result['validation'], 'PASS')
        self.assertEqual(result['totals']['passed'], 4)


if __name__ == '__main__':
    unittest.main()
