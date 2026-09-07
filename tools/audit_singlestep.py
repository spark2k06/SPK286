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
import subprocess

from tools.run_singlestep import OPCODES, REG_ORDER, RESULT_RE, prepare_case, write_batch
from tools.singlestep import is_revoked, load_moo, load_revocation_list


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


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
    for opcode in OPCODES:
        path = args.repo / "v1_real_mode" / f"{opcode}.MOO.gz"
        parsed = load_moo(path)
        with contextlib.redirect_stdout(io.StringIO()):
            cpu, upstream = reference(gzip.decompress(path.read_bytes()))
        require(cpu == parsed.header["cpu_id"], f"{opcode}: CPU mismatch")
        require(len(upstream) == len(parsed.tests) == parsed.header["test_count"], f"{opcode}: count mismatch")
        indexes = set()
        for ours, theirs in zip(parsed.tests, upstream):
            for field, actual in (("idx", ours.index), ("name", ours.name),
                                  ("bytes", list(ours.instruction_bytes)),
                                  ("initial", ours.initial), ("final", ours.final),
                                  ("hash", ours.test_hash), ("exception", ours.exception)):
                require(actual == theirs.get(field), f"{opcode}/{ours.index}: {field} differs from upstream parser")
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
            prefixes += ours.instruction_bytes[0] != int(opcode, 16)
            exceptions += ours.exception is not None
            masked += bool(ours.final.get("reg_masks"))
            if is_revoked(ours, revoked):
                revoked_count += 1
            else:
                prepared = prepare_case(ours, opcode)
                if example is None:
                    example = prepared
        print(f"CORPUS_AUDIT opcode={opcode} header={parsed.header['test_count']} "
              f"parsed={len(parsed.tests)} upstream_equal={len(upstream)}")
    print(f"CORPUS_AUDIT total={total} unique_hashes={len(identities)} cycles={total_cycles} "
          f"revoked={revoked_count} prefixes={prefixes} exceptions={exceptions} masked_cases={masked}")
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
    print("SINGLESTEP_AUDIT PASS: corpus cross-check; 17 rejected fault probes; 2 pristine executions")


if __name__ == "__main__":
    main()
