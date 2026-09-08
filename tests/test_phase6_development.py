"""Development must distinguish known evidence debt from broken validation."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

from tools.phase6_development import POLICIES, validate
from tools.phase6_evidence import validate as strict
from tools.phase6_reports import SUPPORTED_OPCODES, summarize

ROOT = Path(__file__).resolve().parents[1]


class Phase6DevelopmentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / 'evidence.json'
        self.document = json.loads((ROOT / 'docs/phase6_evidence.json').read_text())

    def write(self, document):
        self.path.write_text(json.dumps(document))
        return self.path

    def test_only_recorded_pending_evidence_allows_development(self):
        self.assertEqual(validate(self.write(self.document)), tuple(POLICIES))
        with self.assertRaisesRegex(ValueError, 'unresolved 286 evidence'):
            strict(self.path)

    def test_partial_or_complete_future_resolution_reports_actual_set(self):
        # Synthetic schema examples, never written into production evidence.
        for count in (1, 2, 3):
            document = copy.deepcopy(self.document)
            for decision in document['decisions'][:count]:
                decision.update(status='resolved', resolution='Synthetic test resolution',
                                primary_or_physical_evidence='Synthetic unit-test reference')
            self.assertEqual(validate(self.write(document)), tuple(POLICIES)[count:])
        strict(self.path)

    def test_malformed_or_unapproved_decisions_fail(self):
        changes = [
            lambda d: d.update(schema=True),
            lambda d: d.update(decisions=None),
            lambda d: d['decisions'].pop(),
            lambda d: d['decisions'].append(copy.deepcopy(d['decisions'][0])),
            lambda d: d['decisions'].__setitem__(1, copy.deepcopy(d['decisions'][0])),
            lambda d: d['decisions'].__setitem__(0, None),
            lambda d: d['decisions'][0].update(id='new-ss-shadow'),
            lambda d: d['decisions'][0].update(status='waived'),
            lambda d: d['decisions'][0].update(status='resolved'),
            lambda d: d['decisions'][0].update(candidate='Different policy'),
            lambda d: d['decisions'][0].update(required_evidence=''),
            lambda d: d['decisions'][0].update(reference='Different reference'),
            lambda d: d['decisions'][0].update(resolution='Actually still unresolved'),
            lambda d: d['decisions'][0].update(new_prerequisite='unresolved'),
            lambda d: d.update(new_prerequisite='unresolved'),
        ]
        for change in changes:
            with self.subTest(change=change):
                document = copy.deepcopy(self.document)
                change(document)
                with self.assertRaises(ValueError):
                    validate(self.write(document))
        for text in ('[]', '{', '{"schema":1,"schema":1,"phase":6,"decisions":[]}'):
            self.path.write_text(text)
            with self.assertRaises(ValueError):
                validate(self.path)

    def test_missing_family_and_malformed_reports_fail(self):
        self.assertEqual(len(SUPPORTED_OPCODES), 106)
        self.assertEqual(len(set(SUPPORTED_OPCODES)), 106)
        reports = self.root / 'reports'
        reports.mkdir()
        with self.assertRaisesRegex(ValueError, 'missing/extra hardware opcode reports'):
            summarize(reports)
        for opcode in SUPPORTED_OPCODES:
            (reports / (opcode + '.json')).write_text('{}')
        first = reports / (SUPPORTED_OPCODES[0] + '.json')
        first.write_text('{"opcode":"B8","opcode":"B8"}')
        with self.assertRaisesRegex(ValueError, 'duplicate JSON field'):
            summarize(reports)
        first.write_text('{')
        with self.assertRaises(ValueError):
            summarize(reports)

    @unittest.skipUnless(shutil.which('bash'), 'gate shell requires bash')
    def test_gate_composition_and_specific_failure_propagation(self):
        (self.root / 'scripts').mkdir()
        (self.root / 'bin').mkdir()
        (self.root / 'docs').mkdir()
        shutil.copy2(ROOT / 'scripts/validate_phase6.sh', self.root / 'scripts/validate_phase6.sh')
        shutil.copy2(ROOT / 'docs/phase6_evidence.json', self.root / 'docs/phase6_evidence.json')
        # Only external executable work is stubbed. Actual strict/development
        # evidence validators run against a copied evidence document.
        driver = '''#!{python}
import os, pathlib, runpy, sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open('calls.log','a') as f: f.write(name+' '+' '.join(args)+'\\n')
failure=os.environ.get('TEST_FAIL','')
if failure and failure in name+' '+' '.join(args): sys.exit(23)
if name=='make' and 'singlestep-phase6' in args:
    p=pathlib.Path(os.environ['SPK286_BUILD_DIR'])/'singlestep/reports'
    p.mkdir(parents=True); (p/'B8.json').write_text('{{}}')
if name=='python3' and len(args)>1 and args[1] in ('tools.phase6_development','tools.phase6_evidence'):
    sys.path.insert(0,{root!r})
    sys.argv=args[1:]
    runpy.run_module(args[1],run_name='__main__')
'''.format(python=sys.executable, root=str(ROOT))
        for name in ('python3', 'make', 'git', 'vvp'):
            path = self.root / 'bin' / name
            path.write_text(driver)
            path.chmod(0o755)
        def run(mode, failure='', number=0):
            env = {**os.environ, 'PATH': str(self.root / 'bin') + os.pathsep + os.environ['PATH'],
                   'SPK286_BUILD_DIR': str(self.root / f'fresh-{number}'), 'TEST_FAIL': failure}
            return subprocess.run(['bash', str(self.root / 'scripts/validate_phase6.sh'), mode],
                                  cwd=self.root, env=env, capture_output=True, text=True)
        result = run('executable')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PHASE6_EXECUTABLE_VALIDATION_PASS', result.stdout)
        self.assertIn('PHASE6_ARCHITECTURAL_EVIDENCE_PENDING:', result.stdout)
        self.assertNotIn('PHASE6_VALIDATION_PASS', result.stdout)
        result = run('architectural', number=1)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('stage=architectural-evidence status=1', result.stderr)
        self.assertNotIn('PHASE6_VALIDATION_PASS', result.stdout)
        for number, failure in enumerate(('make phase5-check', 'tools.phase6_reports', 'make event-audit',
                                          'tools.inspect_event_traces', 'make regression', '--check',
                                          'tools.phase6_development'), 2):
            with self.subTest(failure=failure):
                result = run('executable', failure, number)
                self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
                self.assertNotIn('PHASE6_EXECUTABLE_VALIDATION_PASS', result.stdout)
                self.assertNotIn('PHASE6_VALIDATION_PASS', result.stdout)
        evidence = self.root / 'docs/phase6_evidence.json'
        evidence.write_text('{')
        result = run('executable', number=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('PHASE6_EXECUTABLE_VALIDATION_PASS', result.stdout)

    def test_ci_classifies_only_the_known_strict_failure(self):
        self.write(self.document)
        command = [sys.executable, '-m', 'tools.phase6_development', '--ci-status', '--evidence', str(self.path)]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PHASE6_ARCHITECTURAL_EVIDENCE_PENDING:', result.stdout)
        self.path.write_text('{')
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('PHASE6_ARCHITECTURAL_EVIDENCE_PENDING:', result.stdout)

    @unittest.skipUnless(shutil.which('bash'), 'CI shell requires bash')
    def test_ci_status_capture_does_not_mask_validator_failure(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        step = workflow.split('      - name: Classify strict Phase 6 architectural evidence', 1)[1]
        body = textwrap.dedent(step.split('        run: |\n', 1)[1])
        binary = self.root / 'bin'
        binary.mkdir()
        python = binary / 'python3'
        python.write_text('#!/bin/sh\nexit 23\n')
        python.chmod(0o755)
        env = {**os.environ, 'PATH': str(binary) + os.pathsep + os.environ['PATH'],
               'GITHUB_STEP_SUMMARY': str(self.root / 'summary')}
        result = subprocess.run(['bash', '-e', '-c', body], cwd=self.root, env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
