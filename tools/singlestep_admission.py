"""Admission of the single known incomplete physical capture in the corpus.

Strict parsing and CPU expectations are never relaxed; only one exactly
identified record with a verified missing write strobe is reported as not
evaluable instead of failing preparation.
"""
import hashlib
from pathlib import Path

from tools.report_checks import require

REVISION = '37c73caf53dcd22d3dd369ff09305d13d117a4fe'
CAPTURE = {
    'id': 'e7-incomplete-physical-capture',
    'status': 'not_evaluable_incomplete_physical_capture',
    'corpus_revision': REVISION,
    'file': 'v1_real_mode/E7.MOO.gz',
    'index': 1100,
    'hash': 'c56d37647cc2dbcce82ca640fdd25ddea1f3ee5e',
    'source_sha256': 'e163ff1271d61ed9e4cbf6a0150ca3e7b1c756ce7cbcd189e4312eb77b70b729',
    'diagnostic': 'incomplete captured I/O cycle',
}


def validate_dispositions(items, opcode):
    require(isinstance(items, list), 'malformed capture dispositions')
    require(items == ([CAPTURE] if opcode == 'E7' else []),
            'unknown, missing, duplicate or altered incomplete capture disposition')


def admit_incomplete(case, opcode, source, error):
    """Recognize only an unchanged physical file and its verified absent strobe.

    Call only after strict prepare_case failed. The complete compressed identity
    prevents a changed raw record from acquiring this disposition. No payload is
    synthesized from architectural state.
    """
    require(opcode == 'E7' and case.index == CAPTURE['index']
            and case.test_hash == CAPTURE['hash'], 'unrecognized incomplete capture identity')
    require(str(error) == CAPTURE['diagnostic'], 'unrecognized capture failure reason')
    require(Path(source).name == 'E7.MOO.gz'
            and hashlib.sha256(Path(source).read_bytes()).hexdigest() == CAPTURE['source_sha256'],
            'changed incomplete capture source')
    require(case.instruction_bytes == (0xE7, 0x02, 0xF4)
            and case.initial['regs']['ax'] == 0xF6CA
            and case.initial['regs']['ip'] == 0x3848
            and case.final['regs']['ip'] == 0x384B
            and case.exception is None, 'changed incomplete capture context')
    writes = [c for c in case.cycles if (c['t_state'] & 7) == 1 and c['bus_status'] == 10]
    require(len(writes) == 1 and writes[0]['address'] == 2
            and writes[0]['pin_bitfield0'] & 1
            and not any(c['io_status'] for c in case.cycles),
            'capture does not have the verified missing write strobe condition')
    return dict(CAPTURE)


def prepare_population(cases, opcode, source, prepare):
    from tools.singlestep import SingleStepRunnerError
    evaluable, prepared, dispositions = [], [], []
    for case in cases:
        try:
            item = prepare(case)
        except SingleStepRunnerError as error:
            dispositions.append(admit_incomplete(case, opcode, source, error))
            require(len(dispositions) == 1, 'additional incomplete capture')
        else:
            evaluable.append(case)
            prepared.append(item)
    return evaluable, prepared, dispositions
