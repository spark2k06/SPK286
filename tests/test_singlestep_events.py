from copy import deepcopy
import struct
import unittest
from tools.singlestep import SingleStepCase
from tools.run_singlestep import prepare_case, scope_exclusion, SingleStepRunnerError
from tools.audit_singlestep import independent_wire_exceptions
from tools.phase6_reports import validate_report, unique_object
from test_singlestep_runner import REGS


def case(code, exception=None, target=0x2000):
    data=[*code,0xf4]
    value={'idx':0,'name':'independent event adapter case','bytes':data,
           'initial':{'regs':dict(REGS),'ram':[[0x11200+i,b] for i,b in enumerate(data)]},
           'final':{'regs':{'ip':target+1}},'hash':'ab'*20}
    if exception is not None:value['exception']={'number':exception,'flag_address':0x20004}
    return SingleStepCase.from_mapping(value)


class EventAdmissionTests(unittest.TestCase):
    def test_software_event_and_fault_have_distinct_completion(self):
        for code,vector in (([0xcc],3),([0xcd,0xff],255),([0xce],4)):
            p=prepare_case(case(code,vector),f'{code[0]:02X}')
            self.assertEqual((p.expected_event,p.expected_retired,p.expected_regs[12]),(vector,1,0x2000))
        c=case([0x89,0x06,0xff,0xff],13)
        self.assertEqual(scope_exclusion(c,'89'),'exception_delivery')
        self.assertIsNone(scope_exclusion(c,'89',True))
        p=prepare_case(c,'89',True)
        self.assertEqual((p.expected_event,p.expected_retired),(13,0))

    def test_invalid_modrm_ends_target_before_arbitrary_initialized_tail(self):
        for modrm in (0x08,0x4f,0xb9,0xf8):
            for tail in ([],[0x33,0x44],[0x12,0x34,0x56]):
                c=case([0x8f,modrm,*tail],6)
                p=prepare_case(c,'8F',True)
                self.assertEqual((p.expected_event,p.expected_retired),(6,0))
                self.assertEqual(len(p.initial_ram),len(c.instruction_bytes))
        with self.assertRaises(SingleStepRunnerError):
            prepare_case(case([0x8f,0xb9]+[0]*12,6),'8F',True)

    def test_halt_itself_does_not_subtract_sentinel_ip(self):
        p=prepare_case(case([0xf4],target=0x1200),'F4')
        self.assertEqual((p.expected_regs[12],p.expected_event,p.expected_retired),(0x1201,256,1))
        p=prepare_case(case([0xfa],target=0x1201),'FA')
        self.assertEqual(p.expected_regs[12],0x1201)

    def test_strict_excp_wire_parser(self):
        def chunk(tag,data):return tag+struct.pack('<I',len(data))+data
        def record(data):return chunk(b'TEST',struct.pack('<I',7)+data)
        valid=chunk(b'EXCP',b'\x0d'+struct.pack('<I',0xfffffe))
        self.assertEqual(independent_wire_exceptions(record(valid)),{7:{'number':13,'flag_address':0xfffffe}})
        for damaged in (valid+valid,chunk(b'EXCP',b'\x0d'),chunk(b'EXCP',b'\x0d'+struct.pack('<I',1<<24))):
            with self.assertRaises(RuntimeError):independent_wire_exceptions(record(damaged))
        with self.assertRaises(RuntimeError):independent_wire_exceptions(record(valid)+record(valid))

    def test_release_counters_fail_closed(self):
        valid={'opcode':'B8','discovered':5000,'revoked':0,'prefix_skipped':0,'exception_skipped':0,'selection_skipped':0,
               'selected':5000,'executed':5000,'passed':5000,'failed':0,'inherited_selected':5000,'fault_selected':0,
               'phase6_selected':0,'exclusions':[]}
        self.assertEqual(validate_report('B8',valid),valid)
        for field in valid:
            damaged=deepcopy(valid);del damaged[field]
            with self.subTest(field=field),self.assertRaises(ValueError):validate_report('B8',damaged)
        for field,value in (('failed',1),('selected',4999),('executed',4999),('passed',4999),('selection_skipped',1),
                            ('exception_skipped',1),('fault_selected',1),('phase6_selected',5000),('discovered',True),('revoked',1)):
            damaged={**valid,field:value}
            with self.subTest(field=field),self.assertRaises(ValueError):validate_report('B8',damaged)
        with self.assertRaises(ValueError):unique_object([('passed',1),('passed',0)])
