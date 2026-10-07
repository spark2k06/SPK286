"""Far control lengths, file identities and retained invalid-form capture tails."""
import unittest
from tests.test_singlestep_byte_prefix import vector
from tools.singlestep import SingleStepCase
from tools.run_singlestep import prepare_case,scope_exclusion,SingleStepRunnerError


class FarAdmissionTests(unittest.TestCase):
    def test_direct_pointer_and_return_immediates(self):
        for opcode,code in (('9A',[0x9a,0xff,0xff,0xff,0xff]),('EA',[0xea,0,0,1,0]),('CA',[0xca,3,0]),('CB',[0xcb])):
            for prefix in ([],[0xf3,0x36]):
                raw=vector(prefix+code+[0xf4],opcode)
                raw['final']['regs'].update(ip=0x1235,cs=0x6789)
                case=SingleStepCase.from_mapping(raw)
                self.assertIsNone(scope_exclusion(case,opcode,True,True))
                p=prepare_case(case,opcode,True,True)
                self.assertEqual(p.expected_regs[12],0x1234)
                self.assertEqual(p.expected_regs[4],0x6789)
                self.assertEqual(p.initial_ram,p.expected_ram)
                with self.assertRaises(SingleStepRunnerError):
                    prepare_case(SingleStepCase.from_mapping(vector(prefix+code+[0,0xf4],opcode)),opcode,True,True)

    def test_pointer_memory_forms_and_unchanged_invalid_register_tails(self):
        for opcode in ('C4','C5','FF.3','FF.5'):
            for mode in range(4):
                for rm in range(8):
                    group=int(opcode[-1]) if '.' in opcode else 2
                    code=[int(opcode.split('.')[0],16),mode*64+group*8+rm]
                    code += [0x80] if mode==1 else [0x12,0x34] if mode==2 or mode==0 and rm==6 else []
                    tails=range(7) if mode==3 else (0,)
                    for tail in tails:
                        for prefix in ([],[0xf3,0x3e]):
                            raw=vector(prefix+code+list(range(tail))+[0xf4],opcode,6 if mode==3 else None)
                            p=prepare_case(SingleStepCase.from_mapping(raw),opcode,True,True)
                            self.assertEqual(p.initial_ram,p.expected_ram)
                            self.assertEqual(p.source.instruction_bytes,tuple(raw['bytes']))

    def test_invalid_file_group_length_or_fault_identity_is_rejected(self):
        for opcode,code,fault in (('FF.3',[0xff,0x2e,0,0,0xf4],None),('C4',[0xc4,0xc0,0xf4],None),('C5',[0xc5,0xc0,0xf4],13),('FF.5',[0xff,0xe8,0xf4],5),('C4',[0xc4,6,0,0,0,0xf4],None)):
            with self.subTest(opcode=opcode,code=code,fault=fault),self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(vector(code,opcode,fault)),opcode,True,True)
