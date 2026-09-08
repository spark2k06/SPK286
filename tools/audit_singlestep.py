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

from tools.run_singlestep import SUPPORTED_OPCODES, REG_ORDER, RESULT_RE, prepare_case, scope_exclusion, write_batch
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path,
                        default=Path(os.environ.get("SPK286_SINGLESTEP_ROOT", ".cache/singlestep-80286")))
    parser.add_argument("--build-dir", type=Path,
                        default=Path(os.environ.get("SPK286_BUILD_DIR", "build")))
    args = parser.parse_args()
    reference = runpy.run_path(str(args.repo / "tools/moo2json.py"))["parse_moo_bytes"]
    revoked = load_revocation_list(args.repo / "revocation_list.txt")
    total = total_cycles = revoked_count = prefixes = exceptions = masked = 0
    identities = set()
    example = None
    memory_examples = {}
    excluded_count = 0
    for opcode in SUPPORTED_OPCODES:
        path = args.repo / "v1_real_mode" / f"{opcode}.MOO.gz"
        parsed = load_moo(path)
        raw = gzip.decompress(path.read_bytes())
        wire_masks = independent_wire_masks(raw)
        with contextlib.redirect_stdout(io.StringIO()):
            cpu, upstream = reference(raw)
        require(cpu == parsed.header["cpu_id"], f"{opcode}: CPU mismatch")
        require(len(upstream) == len(parsed.tests) == parsed.header["test_count"], f"{opcode}: count mismatch")
        require(set(wire_masks) == {case.index for case in parsed.tests}, f'{opcode}: mask record identities')
        indexes = set()
        for ours, theirs in zip(parsed.tests, upstream):
            for field, actual in (("idx", ours.index), ("name", ours.name),
                                  ("bytes", list(ours.instruction_bytes)),
                                  ("initial", ours.initial),
                                  ("hash", ours.test_hash), ("exception", ours.exception)):
                require(actual == theirs.get(field), f"{opcode}/{ours.index}: {field} differs from upstream parser")
            compare_final_state(ours.final, theirs['final'], wire_masks[ours.index])
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
            elif scope_exclusion(ours, opcode) is not None:
                excluded_count += 1
            else:
                prepared = prepare_case(ours, opcode)
                if example is None:
                    example = prepared
                if opcode in ("89", "8B") and ours.instruction_bytes[1] >> 6 != 3:
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
    values[instruction_address] = 0x90  # Unsupported input: the target must not retire.
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
    print("SINGLESTEP_AUDIT PASS: corpus cross-check; 20 rejected fault probes; 4 pristine executions")


if __name__ == "__main__":
    main()
