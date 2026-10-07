import json
import unittest
from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, generate
from tools.microcode.audit_microcode import canonical_source, read_generated_words


class EventMicrocodeTests(unittest.TestCase):
    def test_frozen_event_contract_and_roundtrip(self):
        sources=json.loads((ROOT/'tests/fixtures/microcode_phase6_sources.json').read_text())
        p=compile_sources(sources)
        contract=json.loads((ROOT/'tests/fixtures/microcode_phase6.json').read_text())
        self.assertEqual(tuple(contract[field] for field in ('format_version','encoding_version','word_width','address_width')),
                         (5,5,6,7))
        generated=generate(p)
        words=read_generated_words(generated['spk286_microcode_pkg.sv'],generated['spk286_microcode_rom.sv'])
        self.assertEqual(list(words),contract['words'])
        self.assertEqual(p.entries,contract['entries'])
        self.assertEqual((p.format_version,p.word_width,p.address_width),(5,6,7))
        rebuilt=compile_sources({'canonical.mc':canonical_source(words,p.entries,p.labels)})
        self.assertEqual(rebuilt.entries,p.entries)
        self.assertEqual(generate(p),generate(compile_sources(dict(reversed(list(sources.items()))))))

    def test_incomplete_reordered_and_post_commit_work_rejected(self):
        for body in ('RESTORE_FLAGS TMP0\nEND', 'POP16 -> TMP0\nPOP16 -> TMP2\nPOP16 -> TMP1\nIRET_COMMIT TMP0 TMP1 TMP2\nEND',
                     'EVENT_ACK\nEVENT_FLAGS -> TMP0\nPUSH16 DECODED TMP0\nEND',
                     'READ_FLAGS -> TMP0\nPUSH16 DECODED TMP0',
                     'REQUEST_EVENT DECODED\nHALT\nEND', 'SET_IF DECODED\nREAD_FLAGS -> TMP0\nEND',
                     'VECTOR_CS -> TMP1\nVECTOR_IP -> TMP0\nCONTEXT_COMMIT TMP0 TMP1\nEND',
                     'HALT\nEND\nHALT\nEND'):
            with self.subTest(body=body),self.assertRaises(CompileError):
                compile_sources({'bad.mc':'microcode_format 5\ninstruction BAD:\n'+body+'\n'})

    def test_old_formats_do_not_admit_events(self):
        for version in range(1,5):
            with self.subTest(version=version),self.assertRaises(CompileError):
                compile_sources({'old.mc':f'microcode_format {version}\ninstruction OLD:\nHALT\nEND\n'})

    def test_pop_precheck_is_frozen_but_event_image_orders_real_fault(self):
        source='microcode_format 5\ninstruction POP:\nDECODE_MODRM\nPOP16 -> TMP0\nTMP0 -> RM16\nEND\n'
        self.assertEqual(len(compile_sources({'p.mc':source}).operations),4)
        with self.assertRaisesRegex(CompileError,'precheck'):
            compile_sources({'p.mc':source.replace('format 5','format 4')})
