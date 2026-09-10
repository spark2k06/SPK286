"""Synthetic admission fixtures; no synthetic transaction is physical evidence."""
import copy
from dataclasses import replace
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from tools import phase7_capture_admission as admission
from tools.run_singlestep import SingleStepRunnerError, captured_io_cycles
from tools.singlestep import SingleStepCase


class CaptureAdmissionTests(unittest.TestCase):
    def fixture(self):
        cycle=dict(t_state=1,bus_status=10,address=2,pin_bitfield0=1,io_status=0,data_bus=0)
        return SingleStepCase(1100,'SYNTHETIC admission fixture',(0xE7,2,0xF4),
                              {'regs':{'ax':0xF6CA,'ip':0x3848}}, {'regs':{'ip':0x384B}},
                              None,admission.CAPTURE['hash'],(cycle,),{})

    def test_exact_condition_and_strict_parser_are_preserved(self):
        case=self.fixture()
        with self.assertRaisesRegex(SingleStepRunnerError,'^incomplete captured I/O cycle$'):
            captured_io_cycles(case)
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory)/'E7.MOO.gz';source.write_bytes(b'SYNTHETIC SOURCE FIXTURE')
            fixture_digest=hashlib.sha256(source.read_bytes()).hexdigest()
            with patch.dict(admission.CAPTURE,source_sha256=fixture_digest):
                result=admission.admit_incomplete(case,'E7',source,SingleStepRunnerError(admission.CAPTURE['diagnostic']))
                self.assertEqual(result,admission.CAPTURE)
                for changed,opcode,error,reason in [
                    (replace(case,index=1101),'E7',admission.CAPTURE['diagnostic'],'identity'),
                    (replace(case,test_hash='0'*40),'E7',admission.CAPTURE['diagnostic'],'identity'),
                    (case,'E6',admission.CAPTURE['diagnostic'],'identity'),
                    (case,'E7','overlapping captured I/O cycles','failure reason'),
                    (replace(case,cycles=(dict(case.cycles[0],io_status=1),)),'E7',admission.CAPTURE['diagnostic'],'strobe condition')]:
                    with self.subTest(reason=reason),self.assertRaisesRegex(ValueError,reason):
                        admission.admit_incomplete(changed,opcode,source,SingleStepRunnerError(error))
                source.write_bytes(b'CHANGED SOURCE')
                with self.assertRaisesRegex(ValueError,'changed incomplete capture source'):
                    admission.admit_incomplete(case,'E7',source,SingleStepRunnerError(admission.CAPTURE['diagnostic']))

    def test_population_rejects_extra_incomplete_and_real_errors(self):
        case=self.fixture()
        def fail(_):raise SingleStepRunnerError('incomplete captured I/O cycle')
        with patch.object(admission,'admit_incomplete',return_value=dict(admission.CAPTURE)):
            self.assertEqual(admission.prepare_population([case],'E7',Path('unused'),fail)[2],[admission.CAPTURE])
            with self.assertRaisesRegex(ValueError,'additional incomplete capture'):
                admission.prepare_population([case,replace(case,index=1101)],'E7',Path('unused'),fail)
        def real_error(_):raise SingleStepRunnerError('architectural mismatch')
        with self.assertRaisesRegex(ValueError,'failure reason'):
            admission.prepare_population([case],'E7',Path('unused'),real_error)

    def test_exact_disposition_inventory(self):
        admission.validate_dispositions([admission.CAPTURE],'E7')
        for items,opcode in [([], 'E7'),([admission.CAPTURE]*2,'E7'),([admission.CAPTURE],'E6'),
                             ([dict(admission.CAPTURE,hash='0'*40)],'E7')]:
            with self.assertRaisesRegex(ValueError,'disposition'):
                admission.validate_dispositions(items,opcode)
