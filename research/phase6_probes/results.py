"""Validate capture provenance and artifact integrity, never adjudicate CPU policy.

Exit zero means a structurally complete record, not physical authenticity, a
passing CPU test, or Phase 6 release. --require-physical rejects every other
provenance. An independent person must inspect the raw captures and controls.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re

from .build import cases

FIELDS = {'schema', 'id', 'test_id', 'provenance', 'status', 'source', 'cpu',
          'fixture', 'initial', 'stimulus', 'observation', 'controls', 'raw_artifacts'}
PROVENANCE = {'physical', 'primary-document', 'simulation', 'not-run'}
REGISTERS = {'ax','bx','cx','dx','sp','bp','si','di','cs','ss','ds','es','ip','flags'}


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON field: {key}')
        result[key] = value
    return result


def finite_float(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError('nonfinite JSON number')
    return value


def nonempty(value, name):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f'missing/non-string {name}')


def require_fields(value, fields, name):
    if not isinstance(value, dict) or not fields <= value.keys():
        raise ValueError(f'missing {name} fields: {sorted(fields)}')


def registers(value, name, allow_unknown=False):
    require_fields(value, REGISTERS, name)
    for key in REGISTERS:
        if allow_unknown and value[key] is None:
            continue
        if type(value[key]) is not int or not 0 <= value[key] <= 65535:
            raise ValueError(f'invalid {name}.{key}')


def validate(record, root, *, require_physical=False):
    if not isinstance(record, dict) or set(record) != FIELDS or type(record['schema']) is not int or record['schema'] != 1:
        raise ValueError('invalid capture schema or unknown/missing fields')
    for field in ('id', 'test_id'):
        nonempty(record[field], field)
    p = record['provenance']
    if p not in PROVENANCE:
        raise ValueError('unknown provenance')
    if require_physical and p != 'physical':
        raise ValueError('physical capture required; synthetic/missing evidence rejected')
    if not isinstance(record['controls'], list) or not isinstance(record['raw_artifacts'], list):
        raise ValueError('controls/raw_artifacts must be arrays')
    if len(record['controls']) != len(set(record['controls'])) or record['id'] in record['controls']:
        raise ValueError('duplicate/self control reference')
    for control in record['controls']:
        nonempty(control, 'control id')
    if p == 'not-run':
        if record['status'] != 'not-run' or record['raw_artifacts'] or record['controls'] or any(
            record[k] is not None for k in ('source','cpu','fixture','initial','stimulus','observation')):
            raise ValueError('not-run cannot contain observations or evidence')
        return dict(provenance=p, admissibility='missing-capture', physical=False)
    expected = {'physical':'captured', 'simulation':'completed', 'primary-document':'examined'}[p]
    if record['status'] != expected:
        raise ValueError('status/provenance mismatch')
    require_fields(record['observation'], {'summary'}, 'observation')
    nonempty(record['observation']['summary'], 'observation.summary')
    kinds, paths = set(), set()
    if not record['raw_artifacts']:
        raise ValueError('missing raw artifacts')
    for artifact in record['raw_artifacts']:
        if not isinstance(artifact, dict) or set(artifact) != {'kind','path','sha256'}:
            raise ValueError('invalid artifact descriptor')
        nonempty(artifact['kind'], 'artifact kind')
        nonempty(artifact['path'], 'artifact path')
        path = PurePosixPath(artifact['path'])
        if path.is_absolute() or '..' in path.parts or '\\' in str(path) or ':' in str(path):
            raise ValueError('unsafe artifact path')
        resolved = (root/path).resolve()
        if not resolved.is_relative_to(root.resolve()) or str(path) in paths:
            raise ValueError('outside/duplicate artifact path')
        if not isinstance(artifact['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', artifact['sha256']):
            raise ValueError('invalid artifact SHA-256')
        data = resolved.read_bytes()
        if not data or hashlib.sha256(data).hexdigest() != artifact['sha256']:
            raise ValueError('empty/corrupt raw artifact')
        paths.add(str(path)); kinds.add(artifact['kind'])
    if p == 'primary-document':
        needed = {'title','publisher','document_number','date','revision','url','page','scope','hypothesis','limitation'}
        require_fields(record['source'], needed, 'primary source')
        for key in needed:
            nonempty(record['source'][key], f'source.{key}')
        if 'original-document' not in kinds:
            raise ValueError('missing original primary artifact')
    else:
        if record['test_id'] not in {c['id'] for c in cases()}:
            raise ValueError('unknown probe test_id')
        require_fields(record['initial'], {'registers','hidden_state','memory_manifest_sha256'}, 'initial')
        registers(record['initial']['registers'], 'initial.registers')
        nonempty(record['initial']['hidden_state'], 'initial.hidden_state')
        if not re.fullmatch('[0-9a-f]{64}', record['initial']['memory_manifest_sha256']):
            raise ValueError('invalid initial-memory manifest hash')
        if not isinstance(record['stimulus'], list) or not record['stimulus']:
            raise ValueError('missing stimulus, including explicit quiet controls')
        for stimulus in record['stimulus']:
            require_fields(stimulus, {'pin','value','reference','offset','unit'}, 'stimulus')
            if stimulus['pin'] not in ('NMI','INTR','RESET','READY') or type(stimulus['value']) is not int or stimulus['value'] not in (0,1):
                raise ValueError('invalid stimulus pin/value')
            for key in ('reference','unit'):
                nonempty(stimulus[key], f'stimulus.{key}')
            if type(stimulus['offset']) not in (int, float) or not math.isfinite(stimulus['offset']):
                raise ValueError('invalid stimulus offset')
        require_fields(record['observation'], {'final_registers','state_method','classification','frames','marker_writes','alignment'}, 'observation')
        registers(record['observation']['final_registers'], 'observation.final_registers',
                  allow_unknown=record['observation']['classification']=='inconclusive')
        for key in ('state_method','classification','alignment'):
            nonempty(record['observation'][key], f'observation.{key}')
        for key in ('frames','marker_writes'):
            if not isinstance(record['observation'][key], list):
                raise ValueError(f'{key} must be an array')
        require_fields(record['fixture'], {'name','firmware_revision','host_revision','clock_hz','clock_method','stop_method','automatic_nmi_dump'}, 'fixture')
        for key in ('name','firmware_revision','host_revision','clock_method','stop_method'):
            nonempty(record['fixture'][key], f'fixture.{key}')
        if type(record['fixture']['automatic_nmi_dump']) is not bool:
            raise ValueError('automatic_nmi_dump must be boolean')
    if p == 'physical':
        if record['fixture']['automatic_nmi_dump']:
            raise ValueError('NMI dump contaminates capture')
        hz = record['fixture']['clock_hz']
        if type(hz) not in (int, float) or not math.isfinite(hz) or hz <= 0:
            raise ValueError('physical clock must be recorded')
        require_fields(record['cpu'], {'family','vendor','part','markings','stepping','voltage'}, 'cpu')
        if record['cpu']['family'] != '80286':
            raise ValueError('physical CPU family must be 80286')
        for key in ('vendor','part','markings','stepping'):
            nonempty(record['cpu'][key], f'cpu.{key}')
        if type(record['cpu']['voltage']) not in (int, float) or not math.isfinite(record['cpu']['voltage']) or record['cpu']['voltage'] <= 0:
            raise ValueError('physical voltage must be recorded')
        if not {'bus','pins','initial-memory','final-memory','cpu-marking','fixture-config'} <= kinds:
            raise ValueError('missing physical raw artifact kinds')
        if not any(a['kind']=='initial-memory' and a['sha256']==record['initial']['memory_manifest_sha256']
                   for a in record['raw_artifacts']):
            raise ValueError('initial-memory manifest is not an identified raw artifact')
        if not record['controls']:
            raise ValueError('physical capture requires repeated controls')
    return dict(provenance=p, admissibility='independent-review-required', physical=p=='physical')


def validate_batch(paths, root, require_physical=False):
    if not paths:
        raise ValueError('empty capture batch')
    records = [json.loads(path.read_text(), object_pairs_hook=unique, parse_float=finite_float,
                          parse_constant=lambda x: (_ for _ in ()).throw(ValueError('nonfinite JSON'))) for path in paths]
    ids = [r.get('id') for r in records]
    if len(ids) != len(set(ids)):
        raise ValueError('duplicate capture id')
    results = [validate(r, root, require_physical=require_physical) for r in records]
    by_id = {r['id']:r for r in records}
    for record in records:
        for control in record['controls']:
            if control not in by_id or (record['provenance']=='physical' and by_id[control]['provenance']!='physical'):
                raise ValueError('missing/nonphysical control capture')
            if record['provenance']=='physical' and (record['cpu'] != by_id[control]['cpu'] or
                                                     record['fixture'] != by_id[control]['fixture']):
                raise ValueError('control CPU/fixture mismatch')
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--require-physical', action='store_true')
    parser.add_argument('records', nargs='+', type=Path)
    args = parser.parse_args()
    try:
        results = validate_batch(args.records, args.root, args.require_physical)
    except (ValueError, OSError, TypeError, KeyError) as error:
        parser.exit(1, f'CAPTURE_RECORD_REJECTED: {error}\n')
    print(json.dumps(dict(records=len(results), physical_records=sum(r['physical'] for r in results),
                          classifications=results, release_approval=False), indent=2))


if __name__ == '__main__':
    main()
