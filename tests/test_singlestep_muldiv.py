# SPDX-License-Identifier: MIT
"""Arithmetic admission and original EXCP/RMSK-bounded FLAGS comparison."""
import copy
from pathlib import Path
import struct
import tempfile
import unittest
from tests.test_singlestep_byte_prefix import vector
from tools.singlestep import SingleStepCase
from tools.run_singlestep import prepare_case,scope_exclusion,write_batch,SingleStepRunnerError


def fault_case(opcode='F6.6',fault=0,mask=0xf72a,odd=0):
    byte=int(opcode.split('.')[0],16)
    code=[byte,0xc0+int(opcode[-1])*8,0xf4] if '.' in opcode else [byte,0,0xf4]
    raw=vector(code,opcode,fault)
    raw['initial']['regs']['ss']=0x2345
    raw['initial']['regs']['sp']=0x1002+odd
    address=0x24450+odd
    raw['exception']['flag_address']=address
    raw['final']['ram']=[[address,0x97],[address+1,0x38],[address-2,0x61]]
    raw['final']['reg_masks']={'flags':mask}
    return raw


class MuldivAdmissionTests(unittest.TestCase):
    def test_all_arithmetic_forms_displacements_and_prefixes(self):
        for opcode in ('69','6B','F6.4','F6.5','F6.6','F6.7','F7.4','F7.5','F7.6','F7.7'):
            for mode in range(4):
                for rm in range(8):
                    extension=int(opcode[-1]) if '.' in opcode else 3
                    code=[int(opcode.split('.')[0],16),mode*64+extension*8+rm]
                    code += [0x81] if mode==1 else [0x12,0x34] if mode==2 or mode==0 and rm==6 else []
                    code += [0xfe,0x80] if opcode=='69' else [0xfe] if opcode=='6B' else []
                    for prefix in ([],[0xf3,0x3e]):
                        original=prefix+code+[0xf4]
                        case=SingleStepCase.from_mapping(vector(original,opcode))
                        self.assertIsNone(scope_exclusion(case,opcode,True,True))
                        result=prepare_case(case,opcode,True,True)
                        self.assertEqual(result.expected_ram,result.initial_ram)
                        self.assertEqual(result.expected_ram_masks,())
                        with self.assertRaises(SingleStepRunnerError):
                            prepare_case(SingleStepCase.from_mapping(vector(prefix+code+[0,0xf4],opcode)),opcode,True,True)

    def test_declared_undefined_bits_only_at_original_saved_flags(self):
        for opcode in ('F6.6','F6.7','F7.6','F7.7'):
            for odd in (0,1):
                for mask in (0xf72a,0xffff,0xfffe):
                    raw=fault_case(opcode,mask=mask,odd=odd)
                    prepared=prepare_case(SingleStepCase.from_mapping(raw),opcode,True,True)
                    address=raw['exception']['flag_address']
                    masks=dict(prepared.expected_ram_masks)
                    self.assertEqual(masks.get(address,255)|(masks.get(address+1,255)<<8),mask)
                    self.assertEqual(dict(prepared.expected_ram),dict(raw['initial']['ram']+raw['final']['ram']))
                    for other in dict(prepared.expected_ram):
                        if other not in (address,address+1):self.assertNotIn(other,masks)

    def test_malformed_metadata_cannot_hide_other_memory_or_defined_flags(self):
        for mutation in ('address','missing_low','missing_high','if_mask','tf_mask','all_mask'):
            raw=fault_case()
            if mutation=='address':raw['exception']['flag_address']-=2
            elif mutation=='missing_low':raw['final']['ram'].pop(0)
            elif mutation=='missing_high':raw['final']['ram'].pop(1)
            else:raw['final']['reg_masks']['flags'] &= ~({'if_mask':0x200,'tf_mask':0x100,'all_mask':0xffff}[mutation])
            with self.subTest(mutation=mutation),self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(raw),'F6.6',True,True)
        for opcode,fault in (('F6.6',13),('F7.7',13),('D4',0)):
            prepared=prepare_case(SingleStepCase.from_mapping(fault_case(opcode,fault)),opcode,True,True)
            self.assertEqual(prepared.expected_ram_masks,())

    def test_unmasked_batches_keep_version_two_and_mixed_masks_use_version_three(self):
        plain=prepare_case(SingleStepCase.from_mapping(fault_case('D4')),'D4',True,True)
        masked=prepare_case(SingleStepCase.from_mapping(fault_case()),'F6.6',True,True)
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'cases.bin'
            for cases,version in (([plain],2),([masked],3),([plain,masked],3)):
                write_batch(path,cases)
                self.assertEqual(path.read_bytes()[:8],b'SPK286SS')
                self.assertEqual(struct.unpack('<II',path.read_bytes()[8:16]),(version,len(cases)))


class CombinedBatchTests(unittest.TestCase):
    def test_version_five_preserves_both_optional_payloads(self):
        from tests.test_singlestep_io import cycle
        raw=vector([0xef,0xf4],'EF')
        raw['cycles']=[cycle(True,4,10,0),cycle(False,4,10,0,1,0x9876)]
        port=prepare_case(SingleStepCase.from_mapping(raw),'EF',True,True)
        fault=prepare_case(SingleStepCase.from_mapping(fault_case()),'F6.6',True,True)
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'mixed.bin';write_batch(path,[fault,port]);data=path.read_bytes()
            self.assertEqual(struct.unpack('<II',data[8:16]),(5,2))
            # The final port extension remains a captured expectation; it is
            # not conflated with the earlier saved-FLAGS byte masks.
            self.assertEqual(data[-12:],struct.pack('<IBIBH',1,1,4,0,0x9876))
            self.assertTrue(fault.expected_ram_masks);self.assertFalse(port.expected_ram_masks)
