"""Strict port capture admission; missing external effects remain errors."""
import copy
import struct
import tempfile
import unittest
from pathlib import Path
from tests.test_singlestep_byte_prefix import vector
from tools.singlestep import SingleStepCase
from tools.run_singlestep import (
    IO_OPCODES, captured_io_cycles, prepare_case,
    scope_exclusion, SingleStepRunnerError, write_batch,
)


def cycle(ts, address, status, bhe, io_status=0, data=0):
    return dict(t_state=1 if ts else 2, address=address, bus_status=status,
                pin_bitfield0=(bhe << 1) | int(ts), io_status=io_status, data_bus=data)


class IoAdmissionTests(unittest.TestCase):
    def test_all_forms_preserve_prefixes_and_memory(self):
        for opcode in IO_OPCODES:
            code=[int(opcode,16)]+([0x93] if opcode in ('E4','E5','E6','E7') else [])+[0xf4]
            for prefix in ([],[0xf2,0x2e],[0xf0,0xf3,0x26]):
                raw=vector(prefix+code,opcode)
                case=SingleStepCase.from_mapping(raw)
                prepared=prepare_case(case,opcode,True,True)
                self.assertIsNone(scope_exclusion(case,opcode,True,True))
                self.assertEqual(prepared.initial_ram,prepared.expected_ram)
                self.assertEqual(prepared.source.instruction_bytes,tuple(prefix+code))
                self.assertEqual(prepared.expected_io,())
            with self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(vector(code[:-1]+[0,0xf4],opcode)),opcode,True,True)
            with self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(vector(code,opcode,6)),opcode,True,True)

    def test_latched_address_lanes_and_completed_port_payload(self):
        raw=vector([0xed,0xf4],'ED')
        raw['cycles']=[cycle(True,0xffff,9,0),cycle(False,0x11223,15,1,4,0xff00),
                       cycle(True,0x10000,9,1),cycle(False,0x22445,15,0,4,0x00ff)]
        self.assertEqual(captured_io_cycles(SingleStepCase.from_mapping(raw)),
                         ((0,0xffff,0,0xff00),(0,0x10000,1,0x00ff)))
        raw['cycles']=[cycle(True,4,10,0),cycle(False,0x8888,15,1,1,0xabcd)]
        self.assertEqual(captured_io_cycles(SingleStepCase.from_mapping(raw)),((1,4,0,0xabcd),))

    def test_incomplete_overlapping_or_inconsistent_capture_is_rejected(self):
        raw=vector([0xef,0xf4],'EF')
        for traffic in ([cycle(True,4,10,0)],
                        [cycle(True,4,10,0),cycle(True,6,10,0)],
                        [cycle(False,4,10,0,1,7)],
                        [cycle(True,4,10,0),cycle(False,4,10,0,4,0xffff)],
                        [cycle(True,5,10,1),cycle(False,5,10,1,1,0xffff)],
                        [cycle(True,4,9,0),cycle(False,4,9,0,4,0x1234)]):
            with self.subTest(traffic=traffic),self.assertRaises(SingleStepRunnerError):
                altered=copy.deepcopy(raw);altered['cycles']=traffic
                captured_io_cycles(SingleStepCase.from_mapping(altered))

    def test_port_extension_does_not_reinterpret_arithmetic_batch_version(self):
        raw=vector([0xef,0xf4],'EF')
        raw['cycles']=[cycle(True,4,10,0),cycle(False,4,10,0,1,0x9876)]
        prepared=prepare_case(SingleStepCase.from_mapping(raw),'EF',True,True)
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'port.bin';write_batch(path,[prepared]);data=path.read_bytes()
            self.assertEqual(data[:8],b'SPK286SS')
            self.assertEqual(struct.unpack('<II',data[8:16]),(4,1))
            self.assertEqual(data[-12:],struct.pack('<IBIBH',1,1,4,0,0x9876))
