"""Run selected SingleStepTests 80286 real-mode vectors against SPK286.

The MOO files remain external.  This adapter reads them directly, applies the
upstream revocation list, emits a compact binary batch, and invokes one
already-built Verilator executable per opcode.  The simulator therefore stays
alive for many vectors instead of being rebuilt or relaunched for each case.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from collections import Counter
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time
from typing import Iterable, Mapping

from tools.singlestep import SingleStepCase, is_revoked, load_revocation_list, load_source


REG_ORDER = (
    "ax", "bx", "cx", "dx", "cs", "ss", "ds", "es",
    "sp", "bp", "si", "di", "ip", "flags",
)
OPCODES = tuple(f"{value:02X}" for value in range(0xB8, 0xC0))
MODRM_OPCODES = ("89", "8B")
ALU_OPCODES = tuple(f'{group*8+form:02X}' for group in range(8) for form in (1, 3, 5)) + tuple(
    f'{opcode}.{group}' for opcode in ('81', '83') for group in range(8))
SUPPORTED_OPCODES = OPCODES + MODRM_OPCODES + ALU_OPCODES
PREFIXES = frozenset((0x26, 0x2E, 0x36, 0x3E, 0xF0, 0xF2, 0xF3))
RESULT_RE = re.compile(
    r"^SINGLESTEP_RESULT executed=(\d+) passed=(\d+) failed=(\d+)(?: cycles=\d+)?$",
    re.MULTILINE,
)


class SingleStepRunnerError(RuntimeError):
    """Raised when a vector cannot be prepared or the runner cannot start."""


@dataclass(frozen=True)
class PreparedCase:
    """The architecture-only data needed by the Verilator batch adapter."""

    source: SingleStepCase
    initial_regs: tuple[int, ...]
    expected_regs: tuple[int, ...]
    expected_masks: tuple[int, ...]
    initial_ram: tuple[tuple[int, int], ...]
    expected_ram: tuple[tuple[int, int], ...]


def scope_exclusion(case: SingleStepCase, opcode: str) -> str | None:
    """ModR/M and Phase 4 forms permit explicit, counted prefix/exception exclusions.

    B8..BF admission remains strict. Unknown encodings and malformed lengths
    are errors; this never catches an arbitrary preparation/execution failure.
    """
    if opcode not in MODRM_OPCODES + ALU_OPCODES:
        return None
    data = case.instruction_bytes
    prefix_count = 0
    while prefix_count < len(data) and data[prefix_count] in PREFIXES:
        prefix_count += 1
    if prefix_count >= len(data) or data[prefix_count] != int(opcode.split('.')[0], 16):
        raise SingleStepRunnerError(f"case {case.index}: file opcode differs from {opcode}")
    if '.' in opcode and (prefix_count+1 >= len(data) or (data[prefix_count+1] >> 3) & 7 != int(opcode[-1])):
        raise SingleStepRunnerError(f"case {case.index}: file group extension differs from {opcode}")
    if prefix_count:
        return "unsupported_prefix"
    if case.exception is not None:
        return "exception_delivery"
    return None


def checked_word(value: object, label: str) -> int:
    if type(value) is not int or not 0 <= value <= 0xFFFF:
        raise SingleStepRunnerError(f"invalid {label}: {value!r}")
    return value


def checked_byte(value: object, label: str) -> int:
    if type(value) is not int or not 0 <= value <= 0xFF:
        raise SingleStepRunnerError(f"invalid {label}: {value!r}")
    return value


def checked_address(value: object, label: str) -> int:
    if type(value) is not int or not 0 <= value <= 0xFFFFFF:
        raise SingleStepRunnerError(f"invalid {label}: {value!r}")
    return value


def read_state_registers(state: Mapping[str, object], label: str) -> list[int]:
    values = state.get("regs", {})
    if not isinstance(values, Mapping):
        raise SingleStepRunnerError(f"{label}.regs is not an object")
    missing = [name for name in REG_ORDER if name not in values]
    if missing:
        raise SingleStepRunnerError(f"{label}.regs is missing {', '.join(missing)}")
    unknown = sorted(set(values) - set(REG_ORDER))
    if unknown:
        raise SingleStepRunnerError(f"{label}.regs has unsupported fields: {unknown}")
    return [checked_word(values[name], f"{label}.{name}") for name in REG_ORDER]


def read_ram(state: Mapping[str, object], label: str) -> dict[int, int]:
    entries = state.get("ram", [])
    if not isinstance(entries, list):
        raise SingleStepRunnerError(f"{label}.ram is not an array")
    values: dict[int, int] = {}
    for entry in entries:
        if not isinstance(entry, list) or len(entry) != 2:
            raise SingleStepRunnerError(f"{label}.ram entry is not [address, byte]: {entry!r}")
        address = checked_address(entry[0], f"{label}.ram address")
        value = checked_byte(entry[1], f"{label}.ram value")
        if address in values and values[address] != value:
            raise SingleStepRunnerError(f"conflicting {label}.ram address {address:06x}")
        values[address] = value
    return values


def read_masks(final_state: Mapping[str, object]) -> list[int]:
    masks = [0xFFFF] * len(REG_ORDER)
    raw_masks = final_state.get("reg_masks", {})
    if not isinstance(raw_masks, Mapping):
        raise SingleStepRunnerError("final.reg_masks is not an object")
    for name, value in raw_masks.items():
        if name not in REG_ORDER:
            raise SingleStepRunnerError(f"final.reg_masks has unsupported register: {name}")
        masks[REG_ORDER.index(name)] = checked_word(value, f"final.{name} mask")
    return masks


def prepare_case(case: SingleStepCase, opcode: str) -> PreparedCase:
    """Convert one sparse MOO state into a full comparison contract."""

    initial = case.initial
    final = case.final
    if case.exception is not None:
        raise SingleStepRunnerError(f"case {case.index}: exception outcomes are unsupported")
    if set(initial) - {"regs", "ram", "queue"}:
        raise SingleStepRunnerError(f"case {case.index}: unsupported initial state fields")
    if set(final) - {"regs", "ram", "queue", "reg_masks"}:
        raise SingleStepRunnerError(f"case {case.index}: unsupported final state fields")
    if initial.get("queue"):
        raise SingleStepRunnerError(f"case {case.index}: non-empty prefetch queue is unsupported")
    if final.get("queue"):
        raise SingleStepRunnerError(f"case {case.index}: final queue is unexpectedly non-empty")
    if len(case.instruction_bytes) < 2 or case.instruction_bytes[-1] != 0xF4:
        raise SingleStepRunnerError(f"case {case.index}: expected terminating HALT byte F4")
    byte_opcode = int(opcode.split('.')[0], 16)
    if case.instruction_bytes[0] != byte_opcode:
        raise SingleStepRunnerError(
            f"case {case.index}: file opcode {case.instruction_bytes[0]:02X} differs from {opcode}"
        )
    if opcode in OPCODES:
        if len(case.instruction_bytes) != 4:
            raise SingleStepRunnerError(f"case {case.index}: supported unprefixed MOV plus HALT requires four bytes")
    elif opcode in ALU_OPCODES and byte_opcode < 0x40 and byte_opcode & 7 == 5:
        if len(case.instruction_bytes) != 4:
            raise SingleStepRunnerError(f"case {case.index}: accumulator immediate length mismatch")
    elif opcode in MODRM_OPCODES + ALU_OPCODES:
        if len(case.instruction_bytes) < 3:
            raise SingleStepRunnerError(f"case {case.index}: missing ModR/M byte")
        mode, rm = case.instruction_bytes[1] >> 6, case.instruction_bytes[1] & 7
        displacement_bytes = 1 if mode == 1 else (2 if mode == 2 or mode == 0 and rm == 6 else 0)
        immediate_bytes = 2 if byte_opcode == 0x81 else (1 if byte_opcode == 0x83 else 0)
        if '.' in opcode and (case.instruction_bytes[1] >> 3) & 7 != int(opcode[-1]):
            raise SingleStepRunnerError(f"case {case.index}: file group extension differs from {opcode}")
        if len(case.instruction_bytes) != 3 + displacement_bytes + immediate_bytes:
            raise SingleStepRunnerError(f"case {case.index}: ModR/M displacement length mismatch")
    else:
        raise SingleStepRunnerError(f"case {case.index}: unsupported opcode {opcode}")

    initial_regs = read_state_registers(initial, "initial")
    initial_flags = initial_regs[REG_ORDER.index("flags")]
    if initial_flags != ((initial_flags & 0x7FD5) | 0x0002):
        raise SingleStepRunnerError(f"case {case.index}: initial FLAGS cannot be represented by current storage")
    final_regs = final.get("regs", {})
    if not isinstance(final_regs, Mapping):
        raise SingleStepRunnerError(f"case {case.index}: final.regs is not an object")
    expected_regs = initial_regs.copy()
    for name, value in final_regs.items():
        if name not in REG_ORDER:
            raise SingleStepRunnerError(f"case {case.index}: unsupported final register {name}")
        expected_regs[REG_ORDER.index(name)] = checked_word(value, f"final.{name}")

    # SingleStep executes the target bytes followed by F4.  The published IP
    # includes that one-byte HALT, so the retirement boundary is final IP - 1.
    published_ip = expected_regs[REG_ORDER.index("ip")]
    retired_ip = (published_ip - 1) & 0xFFFF
    expected_target_ip = (initial_regs[REG_ORDER.index("ip")] + len(case.instruction_bytes) - 1) & 0xFFFF
    if retired_ip != expected_target_ip:
        raise SingleStepRunnerError(
            f"case {case.index}: HALT/IP convention mismatch: published={published_ip:04X} "
            f"target={expected_target_ip:04X}"
        )
    expected_regs[REG_ORDER.index("ip")] = retired_ip

    initial_ram = read_ram(initial, "initial")
    code_base = initial_regs[REG_ORDER.index("cs")] << 4
    initial_ip = initial_regs[REG_ORDER.index("ip")]
    for offset, byte in enumerate(case.instruction_bytes):
        address = code_base + initial_ip + offset
        if initial_ram.get(address) != byte:
            raise SingleStepRunnerError(
                f"case {case.index}: instruction bytes disagree with initial RAM at {address:06X}"
            )
    expected_ram = initial_ram.copy()
    expected_ram.update(read_ram(final, "final"))
    return PreparedCase(
        source=case,
        initial_regs=tuple(initial_regs),
        expected_regs=tuple(expected_regs),
        expected_masks=tuple(read_masks(final)),
        initial_ram=tuple(sorted(initial_ram.items())),
        expected_ram=tuple(sorted(expected_ram.items())),
    )


def write_u8(output, value: int) -> None:
    output.write(struct.pack("<B", value))


def write_u16(output, value: int) -> None:
    output.write(struct.pack("<H", value))


def write_u32(output, value: int) -> None:
    output.write(struct.pack("<I", value))


def write_string(output, value: str) -> None:
    data = value.encode("utf-8")
    write_u32(output, len(data))
    output.write(data)


def write_memory(output, values: Iterable[tuple[int, int]]) -> None:
    values = tuple(values)
    write_u32(output, len(values))
    for address, value in values:
        write_u32(output, address)
        write_u8(output, value)


def write_batch(path: Path, cases: list[PreparedCase]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as output:
        output.write(b"SPK286SS")
        write_u32(output, 1)
        write_u32(output, len(cases))
        for prepared in cases:
            case = prepared.source
            write_u32(output, case.index)
            write_string(output, case.name)
            write_string(output, case.test_hash or "")
            write_u32(output, len(case.instruction_bytes))
            output.write(bytes(case.instruction_bytes))
            for value in prepared.initial_regs:
                write_u16(output, value)
            write_memory(output, prepared.initial_ram)
            for value in prepared.expected_regs:
                write_u16(output, value)
            for value in prepared.expected_masks:
                write_u16(output, value)
            write_memory(output, prepared.expected_ram)


def select_cases(
    cases: tuple[SingleStepCase, ...],
    revoked: frozenset[str],
    sample: int | None,
    full: bool,
    index: int | None,
    test_hash: str | None,
) -> tuple[list[SingleStepCase], int]:
    if index is not None and test_hash is not None:
        raise SingleStepRunnerError("--index and --hash are mutually exclusive")
    if sample is not None and sample < 1:
        raise SingleStepRunnerError("--sample must be positive")
    valid = [case for case in cases if not is_revoked(case, revoked)]
    if index is not None:
        selected = [case for case in valid if case.index == index]
        if not selected:
            raise SingleStepRunnerError(f"test index {index} not found among non-revoked cases")
    elif test_hash is not None:
        selected = [case for case in valid if case.test_hash == test_hash.lower()]
        if not selected:
            raise SingleStepRunnerError(f"test hash {test_hash} not found among non-revoked cases")
    elif full:
        selected = valid
    else:
        selected = valid[: (sample if sample is not None else 10)]
    return selected, len(valid) - len(selected)


def run_opcode(
    opcode: str,
    source_root: Path,
    revoked: frozenset[str],
    args: argparse.Namespace,
    build_dir: Path,
    executable: Path,
) -> tuple[int, int, int, int, int, int, int, int]:
    source_path = source_root / "v1_real_mode" / f"{opcode}.MOO.gz"
    if not source_path.is_file():
        raise SingleStepRunnerError(f"missing SingleStep source: {source_path}")
    cases = load_source(source_path)
    indexes: set[int] = set()
    hashes: set[str] = set()
    for case in cases:
        if case.index in indexes or (case.test_hash is not None and case.test_hash in hashes):
            raise SingleStepRunnerError(f"{source_path}: duplicate case index/hash at {case.index}")
        indexes.add(case.index)
        if case.test_hash is not None:
            hashes.add(case.test_hash)
    eligible = []
    exclusions = []
    for case in cases:
        if is_revoked(case, revoked):
            continue
        reason = scope_exclusion(case, opcode)
        if reason is not None:
            exclusions.append({"index": case.index, "hash": case.test_hash, "reason": reason})
            if args.index == case.index or (args.test_hash is not None and args.test_hash.lower() == case.test_hash):
                raise SingleStepRunnerError(f"case {case.index}: requested case excluded: {reason}")
        else:
            eligible.append(case)
    selected, selection_skipped = select_cases(
        tuple(eligible), frozenset(), args.sample, args.full, args.index, args.test_hash
    )
    prepared = [prepare_case(case, opcode) for case in selected]
    batch_path = build_dir / "singlestep" / "batches" / f"{opcode}.bin"
    write_batch(batch_path, prepared)
    command = [str(executable), "--singlestep-batch", str(batch_path.resolve())]
    if args.trace:
        trace_path = Path(args.trace).resolve()
        trace_path.parent.mkdir(parents=True, exist_ok=True)
        command += ["--trace", str(trace_path)]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    matches = RESULT_RE.findall(result.stdout)
    if len(matches) != 1:
        raise SingleStepRunnerError(
            f"SingleStep simulator failed for {opcode} with status {result.returncode}"
        )
    executed, passed, failed = (int(value) for value in matches[0])
    if result.returncode not in (0, 1):
        raise SingleStepRunnerError(f"SingleStep simulator returned infrastructure error {result.returncode}")
    if executed != len(prepared) or executed != passed + failed:
        raise SingleStepRunnerError(
            f"SingleStep accounting mismatch for {opcode}: selected={len(prepared)} "
            f"executed={executed} passed={passed} failed={failed}"
        )
    if result.returncode != (1 if failed else 0):
        raise SingleStepRunnerError(f"SingleStep result/status mismatch for {opcode}: status={result.returncode}")
    revoked_count = sum(is_revoked(case, revoked) for case in cases)
    reasons = Counter(entry["reason"] for entry in exclusions)
    prefix_skipped, exception_skipped = reasons["unsupported_prefix"], reasons["exception_delivery"]
    if len(cases) != revoked_count + prefix_skipped + exception_skipped + selection_skipped + executed:
        raise SingleStepRunnerError(f"SingleStep discovery accounting mismatch for {opcode}")
    report = {"opcode": opcode, "discovered": len(cases), "revoked": revoked_count,
              "prefix_skipped": prefix_skipped, "exception_skipped": exception_skipped,
              "selection_skipped": selection_skipped, "selected": len(prepared),
              "executed": executed, "passed": passed, "failed": failed, "exclusions": exclusions}
    report_path = build_dir / "singlestep" / "reports" / f"{opcode}.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("SINGLESTEP OPCODE " + " ".join(f"{k}={v}" for k, v in report.items() if k != "exclusions"))
    return len(cases), revoked_count, prefix_skipped, exception_skipped, selection_skipped, executed, passed, failed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(os.environ.get("SPK286_SINGLESTEP_ROOT", ".cache/singlestep-80286")))
    parser.add_argument("--build-dir", type=Path, default=Path(os.environ.get("SPK286_BUILD_DIR", "build")))
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--opcode", dest="opcodes", action="append", choices=SUPPORTED_OPCODES)
    parser.add_argument("--alu", action="store_true", help="select every admitted Phase 4 ALU form")
    parser.add_argument("--full", action="store_true", help="run every non-revoked case")
    parser.add_argument("--sample", type=int, help="run this many deterministic cases per opcode")
    parser.add_argument("--smoke", action="store_true", help="run the fixed ten-case-per-opcode smoke sample")
    parser.add_argument("--index", type=int, help="run one test index; use with one --opcode")
    parser.add_argument("--hash", dest="test_hash", help="run one test hash; use with one --opcode")
    parser.add_argument("--trace", help="write a VCD; requires exactly one selected case")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.alu:
        if args.opcodes:
            raise SingleStepRunnerError('--alu cannot be combined with --opcode')
        args.opcodes = list(ALU_OPCODES)
    if args.full and (args.sample is not None or args.smoke or args.index is not None or args.test_hash is not None):
        raise SingleStepRunnerError("--full cannot be combined with a sample or single-case selector")
    if args.smoke and args.sample is not None:
        raise SingleStepRunnerError("--smoke and --sample are mutually exclusive")
    if args.smoke:
        args.sample = 10
    if args.index is not None or args.test_hash is not None:
        if len(args.opcodes or []) != 1:
            raise SingleStepRunnerError("--index/--hash requires exactly one --opcode")
    if args.trace and not (args.index is not None or args.test_hash is not None):
        raise SingleStepRunnerError("--trace requires --index or --hash")
    source_root = args.repo
    revocation_path = source_root / "revocation_list.txt"
    if not revocation_path.is_file():
        raise SingleStepRunnerError(f"missing revocation list: {revocation_path}")
    executable = args.executable or (args.build_dir / "verilator" / "obj_dir" / "spk286_smoke")
    if not executable.is_file():
        raise SingleStepRunnerError(f"missing Verilator executable: {executable}; run make verilator first")
    opcodes = tuple(args.opcodes or OPCODES)
    if len(set(opcodes)) != len(opcodes):
        raise SingleStepRunnerError("duplicate --opcode selection")
    revoked = load_revocation_list(revocation_path)
    total_discovered = total_revoked = total_selection_skipped = 0
    total_prefix_skipped = total_exception_skipped = 0
    total_executed = total_passed = total_failed = 0
    started = time.perf_counter()
    for opcode in opcodes:
        discovered, revoked_count, prefix_skipped, exception_skipped, selection_skipped, executed, passed, failed = run_opcode(
            opcode, source_root, revoked, args, args.build_dir, executable
        )
        total_discovered += discovered
        total_revoked += revoked_count
        total_prefix_skipped += prefix_skipped
        total_exception_skipped += exception_skipped
        total_selection_skipped += selection_skipped
        total_executed += executed
        total_passed += passed
        total_failed += failed
    elapsed = time.perf_counter() - started
    throughput = total_executed / elapsed if elapsed else 0.0
    print(
        f"SINGLESTEP SUMMARY opcodes={' '.join(opcodes)} discovered={total_discovered} "
        f"revoked/skipped={total_revoked}/{total_selection_skipped} executed={total_executed} "
        f"prefix_skipped={total_prefix_skipped} exception_skipped={total_exception_skipped} selected={total_executed} "
        f"passed={total_passed} failed={total_failed} elapsed={elapsed:.3f}s "
        f"tests/second={throughput:.1f}"
    )
    return 1 if total_failed else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (SingleStepRunnerError, OSError, ValueError) as error:
        print(f"SINGLESTEP ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
