"""Independent data-control encodings and operand/commit protocol checks."""
import json
import unittest
import subprocess
import sys
import tempfile
from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, generate, emit
from tools.microcode.audit_microcode import canonical_source, read_generated_words


class DataMicrocodeTests(unittest.TestCase):
    def test_frozen_data_contract_and_reconstruction(self):
        sources = json.loads((ROOT/'tests/fixtures/microcode_phase7_data_sources.json').read_text())
        program = compile_sources(sources); artifacts = generate(program)
        fixture = json.loads((ROOT/'tests/fixtures/microcode_phase7_data.json').read_text())
        words = read_generated_words(artifacts['spk286_microcode_pkg.sv'], artifacts['spk286_microcode_rom.sv'])
        self.assertEqual(list(words), fixture['words']); self.assertEqual(program.entries, fixture['entries']); self.assertEqual(program.labels, fixture['labels'])
        self.assertEqual((program.format_version, program.word_width, program.address_width), (9, 7, 9))
        self.assertEqual((fixture['format_version'], fixture['encoding_version'], fixture['word_width']), (9, 9, 7))
        rebuilt = compile_sources({'canonical.mc':canonical_source(words, program.entries, program.labels)})
        self.assertEqual([op.operation for op in rebuilt.operations], [op.operation for op in program.operations])
        self.assertEqual(artifacts, generate(compile_sources(dict(reversed(list(sources.items()))))))

    def test_data_source_width_and_commit_protocol_fail_closed(self):
        bodies = ('DECODE_MODRM\nREAD_EA -> TMP0\nTMP0 -> REG16\nEND\n',
                  'DECODE_MODRM\nREAD_RM8 -> TMP1\nREAD_REG8 -> TMP0\nTMP0 -> RM8\nTMP1 -> REG8\nEND\n',
                  'FETCH_IMM16 -> TMP1\nSET_ADDRESS TMP1\nREAD_RM16 -> TMP0\nTMP0 -> DST\nEND\n')
        for body in bodies:
            for i in range(len(body.splitlines())):
                lines = body.splitlines(); lines.pop(i)
                with self.subTest(body=body, missing=i), self.assertRaises(CompileError):
                    compile_sources({'bad.mc':'microcode_format 9\ninstruction BAD:\n'+'\n'.join(lines)})
            for old, new in (('TMP0', 'TMP2'), ('REG8', 'REG16'), ('TMP1 -> REG8\nEND', 'TMP1 -> REG8\nTMP1 -> REG8\nEND')):
                if old not in body: continue
                with self.subTest(old=old), self.assertRaises(CompileError):
                    compile_sources({'bad.mc':'microcode_format 9\ninstruction BAD:\n'+body.replace(old, new)})

    def test_default_audit_cli_selects_active_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, '-m', 'tools.microcode.audit_microcode',
                                     '--output', directory], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertIn('MICROCODE AUDIT PASS', result.stdout)
            stale = subprocess.run([sys.executable, '-m', 'tools.microcode.audit_microcode',
                                    '--output', directory, '--contract',
                                    str(ROOT/'tests/fixtures/microcode_phase7_shift.json')],
                                   cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(stale.returncode, 0)
            self.assertTrue('contract changed' in stale.stderr or 'entry ' in stale.stderr)
