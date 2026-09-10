"""Receipt finalization must reject missing stages, changed logs and stale inputs."""
import json,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from tools import phase7_validation_receipt as receipt
from tools.phase7_capture_admission import CAPTURE


class ReceiptTests(unittest.TestCase):
    def test_valid_execution_fixture_and_invalid_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'inputs.json').write_text('{}')
            (root/'policy-inputs.json').write_text('{}')
            (root/'logs').mkdir()
            for stage in receipt.STAGES:
                (root/'logs'/(stage+'.log')).write_text('SYNTHETIC UNIT FIXTURE\nPHASE7_STAGE_PASS '+stage+'\n')
            physical=dict(validation='PASS',required_population=1386997,
                          totals=dict(discovered=1387000,revoked=3,executed=1386996,passed=1386996,failed=0),
                          not_evaluable=[CAPTURE],unexpected_omissions=0)
            (root/'physical-summary.json').write_text(json.dumps(physical))
            (root/'physical').mkdir();(root/'physical/summary.json').write_text('SYNTHETIC')
            for name in ('reports','identities'):
                d=root/'physical/singlestep'/name;d.mkdir(parents=True)
                for i in range(307):(d/f'{i}.json').write_text('SYNTHETIC')
            d=root/'physical/family-logs';d.mkdir()
            for i in range(307):(d/f'{i}.log').write_text('SYNTHETIC')
            audit=root/'io-audit';audit.mkdir();(audit/'mutant.log').write_text('SYNTHETIC intended failure')
            synthetic=root/'synthetic-io';synthetic.mkdir();(synthetic/'summary.json').write_text('{"validation":"PASS","synthetic_fixture":true}')
            with patch.object(receipt,'execution_snapshot',return_value={}),patch.object(receipt,'policy_snapshot',return_value={}):
                receipt.create(root)
                path=root/'execution-receipt.json';receipt.verify(path)
                saved=path.read_bytes();value=json.loads(saved);value['schema_version']=True
                path.write_text(json.dumps(value))
                with self.assertRaisesRegex(ValueError,'malformed executable receipt'):
                    receipt.verify(path)
                path.write_bytes(saved)
                log=root/'logs/phase7-mutations.log';original=log.read_bytes();log.write_text('failed mutation audit')
                with self.assertRaisesRegex(ValueError,'changed executable result artifact'):
                    receipt.verify(path)
                log.write_bytes(original)
                audit_log=audit/'mutant.log';audit_original=audit_log.read_bytes();audit_log.unlink()
                with self.assertRaisesRegex(ValueError,'missing/extra executable receipt artifacts'):
                    receipt.verify(path)
                audit_log.write_bytes(audit_original)
                synthetic_log=synthetic/'summary.json';synthetic_original=synthetic_log.read_bytes()
                synthetic_log.write_text('{"validation":"FAIL"}')
                with self.assertRaisesRegex(ValueError,'changed executable result artifact'):
                    receipt.verify(path)
                synthetic_log.write_bytes(synthetic_original)
                with patch.object(receipt,'execution_snapshot',return_value={'changed':'rtl'}),self.assertRaisesRegex(ValueError,'source inputs changed'):
                    receipt.verify(path)
                with patch.object(receipt,'policy_snapshot',return_value={'changed':'acceptance'}),self.assertRaisesRegex(ValueError,'policy inputs changed'):
                    receipt.verify(path)
                (root/'physical/singlestep/identities/0.json').unlink()
                with self.assertRaisesRegex(ValueError,'physical artifact inventory'):
                    receipt.verify(path)
            (root/'logs/complete-physical.log').write_text('no completed stage')
            with self.assertRaisesRegex(ValueError,'missing completed executable stage'):
                receipt.result_summary(root)
