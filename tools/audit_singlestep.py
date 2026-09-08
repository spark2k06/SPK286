"""Independently cross-check the external corpus and exercise real RTL failures.

This opt-in audit requires the external upstream moo2json.py reference and an
already-built simulator. No reference code or corpus data is copied into Git.
Deliberate faults exist only in separate ignored batches, never in the source
corpus, production expected-state preparation, or RTL.
"""

import argparse
import contextlib
from dataclasses import replace
import gzip
import io
import os
from pathlib import Path
import runpy
import struct
import subprocess

from tools.run_singlestep import SUPPORTED_OPCODES, PHASE5_OPCODES, PHASE6_OPCODES, REG_ORDER, RESULT_RE, prepare_case, scope_exclusion, write_batch
from tools.singlestep import is_revoked, load_moo, load_revocation_list


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def independent_wire_masks(data):
    """Read MOO 1.1 RMSK independently; the pinned moo2json omits this chunk.

    This audit-only reader shares no chunk/register parsing with production.
    See dbalsom/moo doc/moo_format_v1.md, RMSK and file structure sections.
    """
    names = 'ax bx cx dx cs ss ds es sp bp si di ip flags'.split()

    def chunks(payload):
        stream = io.BytesIO(payload)
        while header := stream.read(8):
            require(len(header) == 8, 'mask audit: truncated chunk header')
            tag, size = struct.unpack('<4sI', header)
            body = stream.read(size)
            require(len(body) == size, 'mask audit: truncated chunk payload')
            yield tag, body

    def masks(payload):
        require(len(payload) >= 2 and len(payload) % 2 == 0, 'mask audit: malformed RMSK')
        words = list(struct.unpack('<' + 'H' * (len(payload) // 2), payload))
        bits = words.pop(0)
        require(bits < 1 << len(names) and bits.bit_count() == len(words),
                'mask audit: RMSK presence/value mismatch')
        return dict(zip((name for bit, name in enumerate(names) if bits & (1 << bit)), words))

    common, records = {}, {}
    for tag, body in chunks(data):
        if tag == b'RMSK':
            require(not records, 'mask audit: late common RMSK')
            common = masks(body)
        elif tag == b'TEST':
            require(len(body) >= 4, 'mask audit: truncated TEST index')
            index = int.from_bytes(body[:4], 'little')
            require(index not in records, 'mask audit: duplicate TEST index')
            effective = dict(common)
            for child, state in chunks(body[4:]):
                require(child != b'RMSK', 'mask audit: RMSK must be common or in FINA')
                if child == b'FINA':
                    for field, value in chunks(state):
                        if field == b'RMSK':
                            for name, mask in masks(value).items():
                                effective[name] = effective.get(name, 0xffff) & mask
            records[index] = effective
    return records


def compare_final_state(actual, upstream, wire_masks):
    # Validate every mask before comparing fields that upstream can represent.
    # Never discard a field merely because moo2json does not implement it.
    require(actual.get('reg_masks', {}) == wire_masks, 'final RMSK differs from independent wire audit')
    common = {key: value for key, value in actual.items() if key != 'reg_masks'}
    require(common == upstream, 'final state differs from upstream parser')


def independent_wire_exceptions(data):
    """Third, audit-only EXCP reader; strict five-byte payload and record identity."""
    def chunks(blob):
        position=0
        while position<len(blob):
            require(position+8<=len(blob),'EXCP audit: truncated chunk header')
            tag=blob[position:position+4]
            size=int.from_bytes(blob[position+4:position+8],'little')
            position+=8
            require(position+size<=len(blob),'EXCP audit: truncated chunk payload')
            yield tag,blob[position:position+size]
            position+=size
    records={}
    for tag,body in chunks(data):
        if tag!=b'TEST': continue
        require(len(body)>=4,'EXCP audit: truncated identity')
        index=int.from_bytes(body[:4],'little')
        require(index not in records,'EXCP audit: duplicate identity')
        records[index]=None
        for tag,value in chunks(body[4:]):
            if tag==b'EXCP':
                require(records[index] is None and len(value)==5,'EXCP audit: duplicate/malformed EXCP')
                address=int.from_bytes(value[1:],'little')
                require(address<1<<24,'EXCP audit: flag address outside physical bus')
                records[index]={'number':value[0],'flag_address':address}
    return records


def memory_probe_candidate(case, opcode):
    """Select a genuine captured MOV operand access, independently of prefixes.

    Register-only MOVs may have prefixes too. Fault-handler IVT/stack traffic
    is not a completed source/destination operand suitable for this probe.
    All records remain subject to the full corpus checks above this selection.
    """
    kind = {'89': 'MEMW', '8B': 'MEMR'}.get(opcode)
    return (kind is not None and case.exception is None and
            any(c['bus_status_name'] == kind for c in case.cycles))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path,
                        default=Path(os.environ.get("SPK286_SINGLESTEP_ROOT", ".cache/singlestep-80286")))
    parser.add_argument("--build-dir", type=Path,
                        default=Path(os.environ.get("SPK286_BUILD_DIR", "build")))
    parser.add_argument('--include-prefixes',action='store_true',help='independently audit newly admitted prefix records')
    args = parser.parse_args()
    reference = runpy.run_path(str(args.repo / "tools/moo2json.py"))["parse_moo_bytes"]
    revoked = load_revocation_list(args.repo / "revocation_list.txt")
    total = total_cycles = revoked_count = prefixes = exceptions = masked = 0
    identities = set()
    example = None
    memory_examples = {}
    stack_control_examples = {}
    event_examples = {}
    fault_examples = {}
    excluded_count = 0
    for opcode in SUPPORTED_OPCODES:
        path = args.repo / "v1_real_mode" / f"{opcode}.MOO.gz"
        parsed = load_moo(path)
        raw = gzip.decompress(path.read_bytes())
        wire_masks = independent_wire_masks(raw)
        wire_exceptions = independent_wire_exceptions(raw)
        with contextlib.redirect_stdout(io.StringIO()):
            cpu, upstream = reference(raw)
        require(cpu == parsed.header["cpu_id"], f"{opcode}: CPU mismatch")
        require(len(upstream) == len(parsed.tests) == parsed.header["test_count"], f"{opcode}: count mismatch")
        require(set(wire_masks) == {case.index for case in parsed.tests}, f'{opcode}: mask record identities')
        require(set(wire_exceptions)==set(wire_masks),f'{opcode}: exception record identities')
        indexes = set()
        for ours, theirs in zip(parsed.tests, upstream):
            for field, actual in (("idx", ours.index), ("name", ours.name),
                                  ("bytes", list(ours.instruction_bytes)),
                                  ("initial", ours.initial),
                                  ("hash", ours.test_hash), ("exception", ours.exception)):
                require(actual == theirs.get(field), f"{opcode}/{ours.index}: {field} differs from upstream parser")
            compare_final_state(ours.final, theirs['final'], wire_masks[ours.index])
            require(ours.exception==wire_exceptions[ours.index],f'{opcode}/{ours.index}: independent EXCP mismatch')
            require(ours.index not in indexes, f"{opcode}: duplicate index")
            require(ours.test_hash is not None and ours.test_hash not in identities, "missing/duplicate global hash")
            indexes.add(ours.index)
            identities.add(ours.test_hash)
            require(len(ours.cycles) == len(theirs["cycles"]), f"{opcode}/{ours.index}: cycle count")
            for actual, expected in zip(ours.cycles, theirs["cycles"]):
                comparable = [actual["pin_bitfield0"], actual["address"], actual["memory_status"],
                              actual["io_status"], actual["data_bus"], actual["bus_status_name"],
                              actual["bus_status"] & 15,
                              {0: "Ti", 1: "Ts", 2: "Tc"}.get(actual["t_state"] & 7, "Ti")]
                require(comparable == expected, f"{opcode}/{ours.index}: decoded cycle differs")
            total_cycles += len(ours.cycles)
            total += 1
            prefixes += ours.instruction_bytes[0] != int(opcode.split('.')[0], 16)
            exceptions += ours.exception is not None
            masked += bool(ours.final.get("reg_masks"))
            if is_revoked(ours, revoked):
                revoked_count += 1
            elif scope_exclusion(ours, opcode, True, args.include_prefixes) is not None:
                excluded_count += 1
            else:
                prepared = prepare_case(ours, opcode, True, args.include_prefixes)
                if opcode in PHASE5_OPCODES and ours.exception is None:
                    stack_control_examples.setdefault(opcode, prepared)
                if opcode in PHASE6_OPCODES:
                    event_examples.setdefault(opcode,prepared)
                if ours.exception is not None:
                    fault_examples.setdefault((opcode in PHASE6_OPCODES,ours.exception['number']),prepared)
                if example is None:
                    example = prepared
                if memory_probe_candidate(ours, opcode):
                    memory_examples.setdefault(opcode, prepared)
        print(f"CORPUS_AUDIT opcode={opcode} header={parsed.header['test_count']} "
              f"parsed={len(parsed.tests)} upstream_equal={len(upstream)}")
    print(f"CORPUS_AUDIT total={total} unique_hashes={len(identities)} cycles={total_cycles} "
          f"revoked={revoked_count} prefixes={prefixes} exceptions={exceptions} "
          f"scope_excluded={excluded_count} masked_cases={masked}")
    require(example is not None, "no supported non-revoked case to probe")

    output = args.build_dir / "singlestep-audit"
    output.mkdir(parents=True, exist_ok=True)
    executable = (args.build_dir / "verilator/obj_dir/spk286_smoke").resolve()

    def execute(name, prepared, reason=None, trace=False):
        batch = output / f"{name}.bin"
        write_batch(batch, [prepared])
        command = [str(executable), "--singlestep-batch", str(batch.resolve())]
        if trace:
            command += ["--trace", str((output / f"{name}.vcd").resolve())]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        (output / f"{name}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        expected = ("1", "0", "1") if reason else ("1", "1", "0")
        require(RESULT_RE.findall(result.stdout) == [expected], f"{name}: wrong result")
        require(result.returncode == (1 if reason else 0), f"{name}: wrong exit status")
        if reason:
            require(reason in result.stdout, f"{name}: wrong failure classification")
        print(f"FAULT_PROBE {name}: {'rejected' if reason else 'passed'} status={result.returncode}")

    execute("pristine", example, trace=True)
    for index, name in enumerate(REG_ORDER):
        values = list(example.expected_regs)
        mask = example.expected_masks[index]
        require(mask != 0, f"{name}: no comparable bit in probe")
        values[index] ^= mask & -mask
        execute(f"expected-{name}", replace(example, expected_regs=tuple(values)),
                "architectural register mismatch")
    values = dict(example.expected_ram)
    address = min(values)
    values[address] ^= 1
    execute("expected-memory", replace(example, expected_ram=tuple(sorted(values.items()))),
            "memory state mismatch")
    instruction_address = ((example.initial_regs[REG_ORDER.index("cs")] << 4)
                           + example.initial_regs[REG_ORDER.index("ip")])
    values = dict(example.initial_ram)
    values[instruction_address + 1] ^= 1
    execute("actual-immediate", replace(example, initial_ram=tuple(sorted(values.items()))),
            "architectural register mismatch")
    values = dict(example.initial_ram)
    values[instruction_address] = 0x0f  # Unsupported system escape: the target must not retire.
    execute("actual-unsupported", replace(example, initial_ram=tuple(sorted(values.items()))),
            "unsupported opcode observed before target retirement")
    execute("pristine-after", example)
    require(set(memory_examples) == {"89", "8B"}, "missing supported memory examples")
    read = memory_examples["8B"]
    write = memory_examples["89"]
    execute("pristine-read", read, trace=True)
    execute("pristine-write", write, trace=True)
    # Use the independently captured bus address, never an RTL-derived EA.
    read_address = next(c["address"] for c in read.source.cycles if c["bus_status_name"] == "MEMR")
    values = dict(read.initial_ram)
    require(read_address in values, "read probe address missing from initial RAM")
    del values[read_address]
    execute("missing-operand-byte", replace(read, initial_ram=tuple(sorted(values.items()))),
            "data read from unspecified sparse RAM")
    values = dict(read.initial_ram)
    values[read_address] ^= 1
    execute("actual-operand-byte", replace(read, initial_ram=tuple(sorted(values.items()))),
            "architectural register mismatch")
    values = dict(write.expected_ram)
    write_address = next(c["address"] for c in write.source.cycles if c["bus_status_name"] == "MEMW")
    require(write_address in values, "write probe address missing from final RAM")
    values[write_address] ^= 1
    execute("expected-operand-byte", replace(write, expected_ram=tuple(sorted(values.items()))),
            "memory state mismatch")
    require(set(stack_control_examples) == set(PHASE5_OPCODES), 'missing Phase 5 comparator probes')
    for opcode, prepared in stack_control_examples.items():
        execute('pristine-stack-control-'+opcode, prepared)
        values = list(prepared.expected_regs)
        values[REG_ORDER.index('ip')] ^= 1
        execute('expected-target-'+opcode, replace(prepared, expected_regs=tuple(values)),
                'architectural register mismatch')
    print("SINGLESTEP_AUDIT PASS: corpus cross-check; 67 rejected fault probes; 51 pristine executions")
    require(set(event_examples)==set(PHASE6_OPCODES),'missing event instruction comparator probes')
    event_probes=0
    for opcode,prepared in event_examples.items():
        execute('pristine-event-'+opcode,prepared,trace=True)
        execute('wrong-completion-'+opcode,replace(prepared,expected_retired=1-prepared.expected_retired),
                'architectural completion mismatch'); event_probes+=1
        for register in ('ip','cs','sp','flags'):
            values=list(prepared.expected_regs); index=REG_ORDER.index(register)
            mask=prepared.expected_masks[index]
            require(mask!=0,'event comparison requires defined bits')
            values[index]^=mask & -mask
            execute('wrong-'+register+'-'+opcode,replace(prepared,expected_regs=tuple(values)),
                    'architectural register mismatch'); event_probes+=1
    require((False,6) in fault_examples and (False,13) in fault_examples,'both inherited fault classes required')
    for key,prepared in fault_examples.items():
        name=('software-' if key[0] else 'fault-')+str(key[1])
        execute('pristine-'+name,prepared,trace=not key[0])
        execute('wrong-vector-'+name,replace(prepared,expected_event=(prepared.expected_event+1)%256),
                'architectural completion mismatch');event_probes+=1
        # EXCP gives the captured FLAGS address; alter each of all six frame
        # bytes independently. Never weaken the full cumulative RAM comparison.
        frame=prepared.source.exception['flag_address']
        for offset in range(-4,2):
            values=dict(prepared.expected_ram);address=frame+offset
            require(address in values,'missing captured event frame byte')
            values[address]^=1
            execute('wrong-frame-'+name+'-'+str(offset+4),replace(prepared,expected_ram=tuple(sorted(values.items()))),
                    'memory state mismatch');event_probes+=1
    print(f'EVENT_COMPARATOR_AUDIT PASS: {event_probes} additional rejected probes; all EXCP/RMSK records independently checked')


if __name__ == "__main__":
    main()
