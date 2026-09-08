"""Discriminating payload mechanics and fail-closed provenance checks."""
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from research.phase6_probes.build import build, cases, verify_encoding
from research.phase6_probes.mechanics import Machine, verify_result
from research.phase6_probes.results import REGISTERS, unique, validate, validate_batch


class ProbeEncodingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        with contextlib.redirect_stdout(io.StringIO()):
            cls.first = build(cls.root/'first')
            cls.second = build(cls.root/'second')

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_deterministic_payloads_and_configs(self):
        # Listing paths differ between runs; deliverable binaries/configs do not.
        self.assertEqual(len(cases()), 21)
        for case in cases():
            for file in ('code.bin','low.bin','stack.bin','reset.bin','config.json'):
                self.assertEqual((self.root/'first'/case['id']/file).read_bytes(),
                                 (self.root/'second'/case['id']/file).read_bytes())

    def test_wrong_target_encoding_is_rejected(self):
        case = next(c for c in cases() if c['id']=='C-gp-tf1')
        code = bytearray((self.root/'first'/case['id']/'code.bin').read_bytes())
        code[0x203] = 0
        with self.assertRaises(AssertionError):
            verify_encoding(code, case)

    def test_every_illustrative_policy_executes_and_discriminates(self):
        import itertools
        observed = {}
        for case in cases():
            directory = self.root/'first'/case['id']
            config = json.loads((directory/'config.json').read_text())
            for iret, sti, tf in itertools.product(('attempt','success'),
                    ('transition','always-renew','always-nonrenew'), ('suppress','immediate','handler-step')):
                result = Machine(directory, dict(iret=iret, sti=sti, fault_tf=tf)).run()
                verify_result(result, config)
                observed[(case['id'],iret,sti,tf)] = result
        a = observed[('A-ffff-second-edge','attempt','transition','suppress')]
        b = observed[('A-ffff-second-edge','success','transition','suppress')]
        self.assertNotEqual(a['markers'], b['markers'])
        self.assertEqual(a['events'][-1]['saved_ip'], 0x400)
        self.assertNotIn('gp', a['markers'])
        self.assertIn('gp', b['markers'])
        for mode, expected in (('suppress',None), ('immediate',0x400), ('handler-step',0x404)):
            result = observed[('C-gp-tf1','attempt','transition',mode)]
            frames = [e for e in result['events'] if e['vector']==1]
            self.assertEqual(frames[0]['saved_ip'] if frames else None, expected)


class CaptureRecordTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.record = dict(schema=1,id='example',test_id='C-gp-tf1',provenance='not-run',status='not-run',
                           source=None,cpu=None,fixture=None,initial=None,stimulus=None,observation=None,
                           controls=[],raw_artifacts=[])

    def envelope(self):
        # Deliberately fabricated parser-test data, never an exported capture.
        r = copy.deepcopy(self.record)
        r.update(provenance='physical',status='captured',
                 cpu=dict(family='80286',vendor='TEST ONLY',part='FABRICATED',markings='parser test',
                          stepping='unknown',voltage=5),
                 fixture=dict(name='FABRICATED',firmware_revision='test',host_revision='test',clock_hz=1,
                              clock_method='synthetic',stop_method='test',automatic_nmi_dump=False),
                 initial=dict(registers={k:0 for k in REGISTERS},hidden_state='test reset',memory_manifest_sha256=''),
                 stimulus=[dict(pin='NMI',value=0,reference='reset',offset=0,unit='synthetic')],
                 observation=dict(summary='FABRICATED PARSER TEST',final_registers={k:0 for k in REGISTERS},
                                  state_method='test',classification='inconclusive',alignment='unavailable',
                                  frames=[],marker_writes=[]), controls=['repeat'])
        for kind in ('bus','pins','initial-memory','final-memory','cpu-marking','fixture-config'):
            data = ('FABRICATED PARSER TEST '+kind).encode()
            (self.root/(kind+'.txt')).write_bytes(data)
            r['raw_artifacts'].append(dict(kind=kind,path=kind+'.txt',sha256=hashlib.sha256(data).hexdigest()))
        r['initial']['memory_manifest_sha256'] = r['raw_artifacts'][2]['sha256']
        return r

    def test_not_run_cannot_be_physical_or_observed(self):
        self.assertFalse(validate(self.record,self.root)['physical'])
        with self.assertRaisesRegex(ValueError,'physical capture required'):
            validate(self.record,self.root,require_physical=True)
        self.record['observation'] = {'summary':'pass'}
        with self.assertRaisesRegex(ValueError,'not-run cannot'):
            validate(self.record,self.root)

    def test_simulation_cannot_be_required_physical(self):
        r = self.envelope(); r['provenance']='simulation';r['status']='completed';r['controls']=[]
        self.assertFalse(validate(r,self.root)['physical'])
        with self.assertRaisesRegex(ValueError,'physical capture required'):
            validate(r,self.root,require_physical=True)

    def test_schema_unknown_missing_duplicate_rejected(self):
        for field in self.record:
            r = dict(self.record);del r[field]
            with self.subTest(field=field), self.assertRaises(ValueError):validate(r,self.root)
        r = dict(self.record,override=True)
        with self.assertRaises(ValueError):validate(r,self.root)
        with self.assertRaisesRegex(ValueError,'duplicate JSON'):
            json.loads('{"provenance":"simulation","provenance":"physical"}',object_pairs_hook=unique)

    def test_incomplete_contaminated_or_corrupt_physical_is_rejected(self):
        mutations = [
            lambda r:r.update(raw_artifacts=[]), lambda r:r.update(controls=[]),
            lambda r:r['fixture'].update(automatic_nmi_dump=True),
            lambda r:r['fixture'].update(clock_hz=0), lambda r:r['cpu'].update(family='80386'),
            lambda r:r['fixture'].update(clock_hz=json.loads('1e999')),
            lambda r:r['cpu'].update(voltage=json.loads('1e999')),
            lambda r:r['stimulus'][0].update(offset=json.loads('1e999')),
            lambda r:r['cpu'].update(stepping=''), lambda r:r['initial']['registers'].pop('flags'),
            lambda r:r['observation']['final_registers'].update(ip=65536),
            lambda r:r['initial'].update(memory_manifest_sha256='0'*64),
            lambda r:r['raw_artifacts'][0].update(path='../escape'),
            lambda r:r['raw_artifacts'][0].update(path='/absolute'),
            lambda r:r['raw_artifacts'][0].update(path='C:\\capture'),
            lambda r:r['raw_artifacts'][0].update(sha256='0'*64),
            lambda r:r.update(stimulus=[]), lambda r:r.update(status='passed'),
        ]
        for index, change in enumerate(mutations):
            r=self.envelope();change(r)
            with self.subTest(index=index), self.assertRaises(ValueError):validate(r,self.root)

    def test_missing_controls_and_other_part_controls_rejected(self):
        r=self.envelope(); first=self.root/'a.json';second=self.root/'b.json'
        first.write_text(json.dumps(r))
        with self.assertRaisesRegex(ValueError,'control capture'):
            validate_batch([first],self.root,True)
        repeated=copy.deepcopy(r);repeated['id']='repeat';repeated['controls']=['example']
        second.write_text(json.dumps(repeated))
        results=validate_batch([first,second],self.root,True)
        self.assertEqual(len(results),2)
        self.assertTrue(all(r['admissibility']=='independent-review-required' for r in results))
        repeated['cpu']['markings']='different physical chip';second.write_text(json.dumps(repeated))
        with self.assertRaisesRegex(ValueError,'CPU/fixture mismatch'):
            validate_batch([first,second],self.root,True)

    def test_empty_batch_and_duplicate_ids_rejected(self):
        with self.assertRaises(ValueError):validate_batch([],self.root)
        p=self.root/'r.json';p.write_text(json.dumps(self.record))
        with self.assertRaisesRegex(ValueError,'duplicate capture id'):
            validate_batch([p,p],self.root)

    def test_nonfinite_nested_json_and_unknown_final_state(self):
        r=self.envelope();r['observation']['frames']=[{'timestamp': 'OVERFLOW'}]
        path=self.root/'overflow.json'
        path.write_text(json.dumps(r).replace('"OVERFLOW"','1e999'))
        with self.assertRaisesRegex(ValueError,'nonfinite JSON'):
            validate_batch([path],self.root)
        r['observation']['final_registers']['flags']=None
        self.assertTrue(validate(r,self.root)['physical'])
        r['observation']['classification']='discriminating'
        with self.assertRaisesRegex(ValueError,'final_registers.flags'):
            validate(r,self.root)


if __name__ == '__main__':
    unittest.main()
