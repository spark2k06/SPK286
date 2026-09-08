import unittest
from tools.run_singlestep import PHASE5_OPCODES, REG_ORDER, SingleStepRunnerError, prepare_case, scope_exclusion
from tools.singlestep import SingleStepCase


def vector(code, final_ip=0x2346):
    regs=dict(zip(REG_ORDER,[0]*len(REG_ORDER)))
    regs.update(ip=0x100,flags=2)
    data=code+[0xf4]
    return SingleStepCase.from_mapping({'bytes':data,'initial':{'regs':regs,'ram':[[0x100+i,b] for i,b in enumerate(data)]},
                                       'final':{'regs':{'ip':final_ip}}})


class StackControlAdapterTests(unittest.TestCase):
    def test_all_47_forms_and_preserved_target(self):
        self.assertEqual(len(PHASE5_OPCODES),47)
        for opcode in PHASE5_OPCODES:
            op=int(opcode.split('.')[0],16)
            control=0x70<=op<=0x7f or op in (0xc2,0xc3,0xe0,0xe1,0xe2,0xe3,0xe8,0xe9,0xeb) or opcode in ('FF.2','FF.4')
            code=[op]
            if op in (0x68,0xc2,0xe8,0xe9):code += [0,0]
            elif op in (0x6a,0xe0,0xe1,0xe2,0xe3,0xeb) or 0x70<=op<=0x7f:code += [0]
            elif op==0x8f:code += [0xc0]
            elif op==0xff:code += [0xc0+8*int(opcode[-1])]
            case=vector(code,0x2346 if control else 0x101+len(code))
            prepared=prepare_case(case,opcode)
            self.assertEqual(prepared.expected_regs[12],0x2345 if control else 0x100+len(code))
            self.assertEqual(prepared.expected_masks,(0xffff,)*14)
            self.assertEqual(prepared.initial_ram,prepared.expected_ram)

    def test_lengths_groups_and_ram_remain_strict(self):
        for code,opcode in (([0xe8,0],'E8'),([0xc3,0],'C3'),([0x8f,0xc8],'8F'),([0xff,0xd0],'FF.4')):
            with self.assertRaises(SingleStepRunnerError):prepare_case(vector(code),opcode)
        with self.assertRaises(SingleStepRunnerError):prepare_case(vector([0x50]),'50')
        case=vector([0xeb,0]);case.initial['ram'][0][1]^=1
        with self.assertRaises(SingleStepRunnerError):prepare_case(case,'EB')

    def test_prefix_is_explicit_exclusion(self):
        self.assertEqual(scope_exclusion(vector([0x36,0x50]),'50'),'unsupported_prefix')
        self.assertIsNone(scope_exclusion(vector([0xe8,0,0]),'E8'))
        with self.assertRaises(SingleStepRunnerError):scope_exclusion(vector([0xff,0xf0]),'FF.2')
