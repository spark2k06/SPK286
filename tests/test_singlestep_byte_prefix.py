import copy
import unittest
from tools.singlestep import SingleStepCase
from tools.run_singlestep import prepare_case, scope_exclusion, SingleStepRunnerError
from tests.test_singlestep_runner import REGS


def vector(code,opcode,exception=None):
    data={'idx':0,'name':'independent admission fixture','bytes':code,'hash':'ba'*20,
          'initial':{'regs':dict(REGS),'ram':[[0x11200+i,b] for i,b in enumerate(code)],'queue':[]},
          'final':{'regs':{'ip':0x1200+len(code)},'ram':[],'queue':[]}}
    if exception is not None:data['exception']={'number':exception,'flag_address':0x22000}
    return data

class BytePrefixAdmissionTests(unittest.TestCase):
    def test_memory_probe_selection_uses_real_access_and_excludes_fault_frames(self):
        from tools.audit_singlestep import memory_probe_candidate
        fixtures = (
            ('8B', [0x26, 0x8b, 0xc3, 0xf4], None, ['CODE'], False),
            ('8B', [0x26, 0x8b, 0x07, 0xf4], None, ['CODE', 'MEMR'], True),
            ('89', [0xf0, 0x89, 0x07, 0xf4], None, ['CODE', 'MEMW'], True),
            ('8B', [0x8b, 0x06, 0xff, 0xff, 0xf4], 13, ['MEMW', 'MEMR'], False),
        )
        for opcode, code, exception, traffic, expected in fixtures:
            with self.subTest(opcode=opcode, code=code, exception=exception):
                raw = vector(code, opcode, exception)
                raw['cycles'] = [{'bus_status_name': kind} for kind in traffic]
                self.assertEqual(memory_probe_candidate(SingleStepCase.from_mapping(raw), opcode), expected)

    def test_widths_and_prefix_readmission_do_not_change_saved_bytes(self):
        for opcode,code in [('B4',[0xb4,0x83,0xf4]),('00',[0,0xc4,0xf4]),('C6',[0xc6,0xc0,0x17,0xf4]),('C7',[0xc7,0xc0,0x17,0x83,0xf4])]:
            for prefixes in ([],[0x26],[0x36,0x2e,0x3e,0xf0],[0xf2,0xf3]):
                with self.subTest(opcode=opcode,prefixes=prefixes):
                    raw=vector(prefixes+code,opcode);case=SingleStepCase.from_mapping(raw)
                    self.assertIsNone(scope_exclusion(case,opcode,True,True))
                    prepared=prepare_case(case,opcode,True,True)
                    self.assertEqual(prepared.source.instruction_bytes,tuple(prefixes+code))
                    self.assertEqual(prepared.expected_regs[12],0x1200+len(prefixes+code)-1)
                    self.assertEqual(dict(prepared.initial_ram),dict(raw['initial']['ram']))
                    self.assertEqual(prepared.expected_ram,prepared.initial_ram)
                    if prefixes:self.assertEqual(scope_exclusion(case,opcode,True),'unsupported_prefix')

    def test_early_fault_halt_tail_is_not_an_operand_or_discarded_ram(self):
        for opcode,code in [('C6',[0xc6,0x55,0xf4,0x27]),('C7',[0xc7,0xfd,0xf4,0xd3])]:
            raw=vector(code,opcode,6);case=SingleStepCase.from_mapping(raw)
            p=prepare_case(case,opcode,True)
            self.assertEqual((p.expected_event,p.expected_retired),(6,0))
            self.assertEqual(len(p.initial_ram),len(code))
            for change in ('vector','sentinel','missing_ram','valid_extension'):
                bad=copy.deepcopy(raw)
                if change=='vector':bad['exception']['number']=13
                if change=='sentinel':bad['bytes'][2]=0x90
                if change=='missing_ram':bad['initial']['ram'].pop()
                if change=='valid_extension':bad['bytes'][1]=0xc0
                with self.subTest(change=change),self.assertRaises(SingleStepRunnerError):prepare_case(SingleStepCase.from_mapping(bad),opcode,True)

    def test_unexecuted_jump_tail_keeps_complete_memory_contract(self):
        raw=vector([0x3e,0xeb,0x9d,0x3e,0xeb,2,0xf4],'EB')
        raw['final']['regs']['ip']=0x1200+3-99+1
        p=prepare_case(SingleStepCase.from_mapping(raw),'EB',True,True)
        self.assertEqual(p.expected_regs[12],0x1200+3-99)
        self.assertEqual(len(p.initial_ram),7)
        for code in ([0x3e,0xeb,0xf4],[0x3e,0xeb,0x9d,0x90]):
            with self.assertRaises(SingleStepRunnerError):prepare_case(SingleStepCase.from_mapping(vector(code,'EB')),'EB',True,True)
