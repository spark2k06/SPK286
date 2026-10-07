"""Run selected SingleStepTests 80286 real-mode vectors against SPK286.

The MOO files remain external.  This adapter reads them directly, applies the
upstream revocation list, emits a compact binary batch, and invokes one
already-built Verilator executable per opcode.  The simulator therefore stays
alive for many vectors instead of being rebuilt or relaunched for each case.
"""

from __future__ import annotations

import argparse
import hashlib
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
PHASE5_OPCODES = tuple(f'{value:02X}' for value in range(0x50,0x60)) + ('68','6A') + tuple(
    f'{value:02X}' for value in range(0x70,0x80)) + ('8F','C2','C3','E0','E1','E2','E3','E8','E9','EB','FF.2','FF.4','FF.6')
CONTROL_OPCODES = tuple(f'{value:02X}' for value in range(0x70,0x80)) + ('C2','C3','E0','E1','E2','E3','E8','E9','EB','FF.2','FF.4')
PHASE6_OPCODES = ('9C','9D','CC','CD','CE','CF','F4','FA','FB')
INHERITED_OPCODES = OPCODES + MODRM_OPCODES + ALU_OPCODES + PHASE5_OPCODES
BYTE_SCALAR_OPCODES = tuple(f'{v:02X}' for v in range(0xB0,0xB8)) + ('88','8A','C6','C7') + tuple(f'{g*8+f:02X}' for g in range(8) for f in (0,2,4)) + tuple(f'80.{g}' for g in range(8))
TEST_OPCODES = ('84','85','A8','A9','F6.0','F7.0')
SCALAR_DIRECT_OPCODES = tuple(f'{v:02X}' for v in range(0x40,0x50)) + ('98','99','9E','9F','F5','F8','F9','FC','FD')
# Compatibility extensions beyond the documented 80286 instruction set.
COMPATIBILITY_OPCODES = ('D6',)
NPX_OPCODES = ('9B', 'D8')  # Public no-NPX captures; MSW traps use directed banks.
SHIFT_OPCODES = tuple(f'{op}.{g}' for op in ('C0','C1','D0','D1','D2','D3') for g in (0,1,2,3,4,5,7))
DATA_OPCODES = ('86','87','8D','D7','A0','A1','A2','A3') + tuple(f'{v:02X}' for v in range(0x90,0x98))
UNARY_OPCODES = ('F6.2','F6.3','F7.2','F7.3','FE.0','FE.1','FF.0','FF.1')
ADJUST_OPCODES = ('27','2F','37','3F','D4','D5')
SEGMENT_OPCODES = ('06','07','0E','16','17','1E','1F','8C','8E')
STACK_FRAME_OPCODES = ('60','61','62','C8','C9')
MULDIV_OPCODES = ('69','6B') + tuple(f'{op}.{kind}' for op in ('F6','F7') for kind in range(4,8))
DIVIDE_OPCODES = ('F6.6','F6.7','F7.6','F7.7')
FAR_OPCODES = ('C4','C5','9A','EA','CA','CB','FF.3','FF.5')
SCALAR_IO_OPCODES = ('E4','E5','E6','E7','EC','ED','EE','EF')
STRING_IO_OPCODES = ('6C','6D','6E','6F')
IO_OPCODES = SCALAR_IO_OPCODES + STRING_IO_OPCODES
STRING_OPCODES = ('A4','A5','A6','A7','AA','AB','AC','AD','AE','AF')
CONTROL_OPCODES += ('9A','EA','CA','CB','FF.3','FF.5')
SUPPORTED_OPCODES = INHERITED_OPCODES + PHASE6_OPCODES + BYTE_SCALAR_OPCODES + TEST_OPCODES + SCALAR_DIRECT_OPCODES + SHIFT_OPCODES + DATA_OPCODES + UNARY_OPCODES + ADJUST_OPCODES + SEGMENT_OPCODES + STACK_FRAME_OPCODES + FAR_OPCODES + STRING_OPCODES + IO_OPCODES + MULDIV_OPCODES
SUPPORTED_OPCODES += COMPATIBILITY_OPCODES + NPX_OPCODES
PREFIXES = frozenset((0x26, 0x2E, 0x36, 0x3E, 0xF0, 0xF2, 0xF3))
RESULT_RE = re.compile(
    r"^SINGLESTEP_RESULT executed=(\d+) passed=(\d+) failed=(\d+)(?: cycles=\d+)?$",
    re.MULTILINE,
)


from tools.singlestep import SingleStepRunnerError


@dataclass(frozen=True)
class PreparedCase:
    """The architecture-only data needed by the Verilator batch adapter."""

    source: SingleStepCase
    initial_regs: tuple[int, ...]
    expected_regs: tuple[int, ...]
    expected_masks: tuple[int, ...]
    initial_ram: tuple[tuple[int, int], ...]
    expected_ram: tuple[tuple[int, int], ...]
    expected_ram_masks: tuple[tuple[int, int], ...] = ()
    expected_event: int = 256
    expected_retired: int = 1
    expected_io: tuple[tuple[int,int,int,int], ...] = ()


def scope_exclusion(case: SingleStepCase, opcode: str, include_exceptions: bool = False, include_prefixes: bool = False) -> str | None:
    """ModR/M and ALU forms permit explicit, counted prefix/exception exclusions.

    B8..BF admission remains strict. Unknown encodings and malformed lengths
    are errors; this never catches an arbitrary preparation/execution failure.
    """
    if opcode not in MODRM_OPCODES + ALU_OPCODES + PHASE5_OPCODES + PHASE6_OPCODES + BYTE_SCALAR_OPCODES + TEST_OPCODES + SCALAR_DIRECT_OPCODES + SHIFT_OPCODES + DATA_OPCODES + UNARY_OPCODES + ADJUST_OPCODES + SEGMENT_OPCODES + STACK_FRAME_OPCODES + FAR_OPCODES + STRING_OPCODES + IO_OPCODES + MULDIV_OPCODES + COMPATIBILITY_OPCODES + NPX_OPCODES:
        return None
    data = case.instruction_bytes
    prefix_count = 0
    while prefix_count < len(data) and data[prefix_count] in PREFIXES:
        prefix_count += 1
    if prefix_count >= len(data) or data[prefix_count] != int(opcode.split('.')[0], 16):
        raise SingleStepRunnerError(f"case {case.index}: file opcode differs from {opcode}")
    if '.' in opcode and (prefix_count+1 >= len(data) or (data[prefix_count+1] >> 3) & 7 != int(opcode[-1])):
        raise SingleStepRunnerError(f"case {case.index}: file group extension differs from {opcode}")
    if prefix_count and not include_prefixes:
        return "unsupported_prefix"
    if case.exception is not None and not (include_exceptions or opcode in PHASE6_OPCODES):
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


def captured_io_cycles(case):
    """Latched Ts address/BHE, completed Tc data; expected records only.

    Physical addresses can advance before Tc. These observations never supply
    input stimulus: scalar IN's capture responder independently returns FF.
    """
    pending=None;cycles=[]
    for cycle in case.cycles:
        ts=(cycle['t_state']&7)==1
        tc=(cycle['t_state']&7)==2
        if ts and cycle['bus_status'] in (9,10):
            if pending is not None:raise SingleStepRunnerError('overlapping captured I/O cycles')
            pending=(int(cycle['bus_status']==10),checked_address(cycle['address'],'I/O address'),(cycle['pin_bitfield0']>>1)&1)
            if not cycle['pin_bitfield0']&1:raise SingleStepRunnerError('missing captured I/O address latch')
        if tc and cycle['io_status']:
            if pending is None:raise SingleStepRunnerError('I/O completion without address latch')
            write,address,bhe=pending
            if cycle['io_status']!=(1 if write else 4):raise SingleStepRunnerError('captured I/O direction mismatch')
            mask=0xff00 if address&1 else (0xff if bhe else 0xffff)
            if address&1 and bhe:raise SingleStepRunnerError('captured I/O with no selected byte lane')
            data=checked_word(cycle['data_bus'],'I/O data')&mask
            if not write and data!=mask:raise SingleStepRunnerError('capture violates documented FF I/O responder')
            cycles.append((write,address,bhe,data));pending=None
    if pending is not None:raise SingleStepRunnerError('incomplete captured I/O cycle')
    return tuple(cycles)


def prepare_case(case: SingleStepCase, opcode: str, include_exceptions: bool = False, include_prefixes: bool = False) -> PreparedCase:
    """Convert one sparse MOO state into a full comparison contract."""

    instruction_bytes = case.instruction_bytes
    if include_prefixes:
        prefix_count=0
        while prefix_count<len(instruction_bytes) and instruction_bytes[prefix_count] in PREFIXES:
            prefix_count+=1
        instruction_bytes=instruction_bytes[prefix_count:]
        if not instruction_bytes:
            raise SingleStepRunnerError(f'case {case.index}: missing opcode after prefixes')
    initial = case.initial
    final = case.final
    if case.exception is not None and not (include_exceptions or opcode in PHASE6_OPCODES):
        raise SingleStepRunnerError(f"case {case.index}: exception outcomes are unsupported")
    expected_event=256
    expected_retired=1
    if case.exception is not None:
        if set(case.exception) != {'number','flag_address'}:
            raise SingleStepRunnerError(f'case {case.index}: malformed EXCP fields')
        expected_event=checked_byte(case.exception['number'],'EXCP vector')
        checked_address(case.exception['flag_address'],'EXCP flag address')
        expected_retired=int(opcode in ('CC','CD','CE'))
        if opcode in STRING_OPCODES + IO_OPCODES and expected_event != 13:
            raise SingleStepRunnerError(f'case {case.index}: string fault must be #GP')
        if not expected_retired and expected_event not in (6,13) and not (opcode in ('D4',) + DIVIDE_OPCODES and expected_event == 0) and not (opcode == '62' and expected_event == 5):
            raise SingleStepRunnerError(f'case {case.index}: unsupported architectural fault producer')
    if set(initial) - {"regs", "ram", "queue"}:
        raise SingleStepRunnerError(f"case {case.index}: unsupported initial state fields")
    if set(final) - {"regs", "ram", "queue", "reg_masks"}:
        raise SingleStepRunnerError(f"case {case.index}: unsupported final state fields")
    if initial.get("queue"):
        raise SingleStepRunnerError(f"case {case.index}: non-empty prefetch queue is unsupported")
    if final.get("queue"):
        raise SingleStepRunnerError(f"case {case.index}: final queue is unexpectedly non-empty")
    # Invalid immediate-MOV encodings fault at ModR/M. The physical generator
    # replaces the first unconsumed byte with HLT, retaining the remaining tail.
    # Admit only that documented shape; every recorded RAM byte stays compared.
    early_halt = (opcode in ('C6','C7') and len(instruction_bytes) >= 3 and
                  (instruction_bytes[1] >> 3) & 7 != 0 and
                  instruction_bytes[2] == 0xF4 and expected_event == 6)
    if len(instruction_bytes) < 2 or (instruction_bytes[-1] != 0xF4 and not early_halt):
        raise SingleStepRunnerError(f"case {case.index}: expected terminating HALT byte F4")
    byte_opcode = int(opcode.split('.')[0], 16)
    if instruction_bytes[0] != byte_opcode:
        raise SingleStepRunnerError(
            f"case {case.index}: file opcode {instruction_bytes[0]:02X} differs from {opcode}"
        )
    if opcode in BYTE_SCALAR_OPCODES and (0xB0 <= byte_opcode < 0xB8 or byte_opcode < 0x40 and byte_opcode & 7 == 4):
        if len(instruction_bytes) != 3:
            raise SingleStepRunnerError(f'case {case.index}: byte immediate length mismatch')
    elif opcode in SCALAR_DIRECT_OPCODES + COMPATIBILITY_OPCODES + STRING_OPCODES + STRING_IO_OPCODES + ('9B','27','2F','37','3F','60','61','C9','D7','06','07','0E','16','17','1E','1F') + tuple(f'{v:02X}' for v in range(0x90,0x98)):
        if len(instruction_bytes) != 2:
            raise SingleStepRunnerError(f'case {case.index}: scalar single-byte instruction length mismatch')
    elif opcode in ('9A','EA','CA','CB'):
        if len(instruction_bytes) != (6 if opcode in ('9A','EA') else 4 if opcode=='CA' else 2):
            raise SingleStepRunnerError(f'case {case.index}: far control immediate length mismatch')
    elif opcode == 'C8':
        if len(instruction_bytes) != 5:
            raise SingleStepRunnerError(f'case {case.index}: ENTER immediate length mismatch')
    elif opcode in ('D4','D5'):
        if len(instruction_bytes) != 3:
            raise SingleStepRunnerError(f'case {case.index}: adjust radix length mismatch')
    elif opcode in ('A0','A1','A2','A3'):
        if len(instruction_bytes) != 4:
            raise SingleStepRunnerError(f'case {case.index}: direct address length mismatch')
    elif opcode in ('A8','A9'):
        if len(instruction_bytes) != (3 if opcode == 'A8' else 4):
            raise SingleStepRunnerError(f'case {case.index}: TEST accumulator immediate length mismatch')
    elif opcode in OPCODES:
        if len(instruction_bytes) != 4:
            raise SingleStepRunnerError(f"case {case.index}: supported unprefixed MOV plus HALT requires four bytes")
    elif opcode in SCALAR_IO_OPCODES:
        if len(instruction_bytes)!=(3 if byte_opcode<0xE8 else 2):
            raise SingleStepRunnerError(f'case {case.index}: scalar I/O length mismatch')
    elif opcode in PHASE6_OPCODES:
        if len(instruction_bytes) != (3 if opcode=='CD' else 2):
            raise SingleStepRunnerError(f'case {case.index}: event instruction length mismatch')
    elif opcode in ALU_OPCODES and byte_opcode < 0x40 and byte_opcode & 7 == 5:
        if len(instruction_bytes) != 4:
            raise SingleStepRunnerError(f"case {case.index}: accumulator immediate length mismatch")
    elif opcode in PHASE5_OPCODES and byte_opcode not in (0x8F, 0xFF):
        instruction_length = (3 if byte_opcode in (0x68,0xC2,0xE8,0xE9) else
                              2 if byte_opcode in (0x6A,0xE0,0xE1,0xE2,0xE3,0xEB) or 0x70 <= byte_opcode <= 0x7F else 1)
        # Some unconditional-jump captures retain unexecuted generator tail
        # bytes after the displacement. Preserve them as compared RAM; the
        # target fetch is the capture's terminating HLT convention.
        length_ok = (instruction_length+1 <= len(instruction_bytes) <= 11 if byte_opcode in (0xE9,0xEB)
                     else len(instruction_bytes) == instruction_length+1)
        if not length_ok:
            raise SingleStepRunnerError(f'case {case.index}: stack/control length mismatch')
    elif opcode in MODRM_OPCODES + ALU_OPCODES + BYTE_SCALAR_OPCODES + TEST_OPCODES + SHIFT_OPCODES + UNARY_OPCODES + MULDIV_OPCODES + ('D8','86','87','8D','8C','8E','62','C4','C5','FF.3','FF.5') + ('8F','FF.2','FF.4','FF.6'):
        if len(instruction_bytes) < 3:
            raise SingleStepRunnerError(f"case {case.index}: missing ModR/M byte")
        if byte_opcode == 0x8F and (instruction_bytes[1] >> 3) & 7 != 0 and not include_exceptions:
            raise SingleStepRunnerError(f'case {case.index}: invalid POP group extension')
        mode, rm = instruction_bytes[1] >> 6, instruction_bytes[1] & 7
        displacement_bytes = 1 if mode == 1 else (2 if mode == 2 or mode == 0 and rm == 6 else 0)
        immediate_bytes = (2 if opcode == '69' else 1 if opcode == '6B' else 0) if opcode in MULDIV_OPCODES else 0 if opcode in UNARY_OPCODES else 2 if byte_opcode in (0x81,0xC7,0xF7) else (1 if byte_opcode in (0x80,0x83,0xC6,0xF6,0xC0,0xC1) else 0)
        if '.' in opcode and (instruction_bytes[1] >> 3) & 7 != int(opcode[-1]):
            raise SingleStepRunnerError(f"case {case.index}: file group extension differs from {opcode}")
        # Invalid POP extensions end decoding at ModR/M. The generator can leave
        # additional bytes before its HLT sentinel; they are initialized memory,
        # not an operand displacement to execute. Keep every byte for comparison.
        invalid_pop = byte_opcode in (0x8F,0xC6,0xC7) and (instruction_bytes[1] >> 3) & 7 != 0
        # A register-form BOUND raises #UD at ModR/M; the physical generator
        # retains unused bound-data tail bytes. Keep all of them as RAM.
        invalid_bound = (byte_opcode in (0x62,0xC4,0xC5) or opcode in ('FF.3','FF.5')) and mode == 3
        if invalid_bound and (case.exception is None or case.exception.get('number') != 6):
            raise SingleStepRunnerError(f'case {case.index}: register-only pointer/bound form requires #UD evidence')
        invalid_pop = invalid_pop or invalid_bound
        if invalid_pop and not 3 <= len(instruction_bytes) <= 11:
            raise SingleStepRunnerError(f'case {case.index}: invalid-form capture length out of bounds')
        if not invalid_pop and len(instruction_bytes) != 3+displacement_bytes+immediate_bytes:
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
    # Control-transfer vectors inject HLT on the first target fetch (upstream
    # README). Preserve the published target; do not enforce sequential IP.
    published_ip = expected_regs[REG_ORDER.index("ip")]
    # F4 itself stops capture before the appended sentinel executes.
    retired_ip = (published_ip - (0 if opcode=='F4' else 1)) & 0xFFFF
    expected_target_ip = (initial_regs[REG_ORDER.index("ip")] + len(case.instruction_bytes) - 1) & 0xFFFF
    if opcode not in CONTROL_OPCODES + ('CF',) and case.exception is None and retired_ip != expected_target_ip:
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
    final_ram=read_ram(final, "final")
    expected_ram.update(final_ram)
    masks=read_masks(final)
    frame_masks=[]
    if opcode in DIVIDE_OPCODES and expected_event == 0:
        # Intel leaves only these six arithmetic bits undefined. The original
        # corpus RMSK and EXCP locate their comparison mask; no expected byte
        # or CPU result is changed. Other faults retain exact RAM comparison.
        flags_mask=masks[REG_ORDER.index("flags")]
        if flags_mask | 0x08D5 != 0xFFFF:
            raise SingleStepRunnerError("DIV FLAGS mask excludes a defined bit")
        flag_address=case.exception['flag_address']
        frame_address=(initial_regs[REG_ORDER.index("ss")] << 4) + ((initial_regs[REG_ORDER.index("sp")]-2) & 0xFFFF)
        if flag_address != frame_address or any(flag_address+i not in final_ram for i in (0,1)):
            raise SingleStepRunnerError("DIV EXCP FLAGS address is not the captured stack word")
        frame_masks=[(flag_address+i,(flags_mask >> (i*8)) & 255) for i in (0,1) if ((flags_mask >> (i*8)) & 255) != 255]
    return PreparedCase(
        source=case,
        initial_regs=tuple(initial_regs),
        expected_regs=tuple(expected_regs),
        expected_masks=tuple(masks),
        expected_ram_masks=tuple(frame_masks),
        initial_ram=tuple(sorted(initial_ram.items())),
        expected_ram=tuple(sorted(expected_ram.items())),
        expected_event=expected_event,
        expected_retired=expected_retired,
        expected_io=captured_io_cycles(case) if opcode in IO_OPCODES else (),
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
        # Preserve v2, v3 (RAM masks) and v4 (port comparisons). Version 5
        # carries both extensions for batches that require both capabilities.
        has_masks=any(p.expected_ram_masks for p in cases)
        has_io=any(p.expected_io for p in cases)
        version=5 if has_masks and has_io else 3 if has_masks else 4 if has_io else 2
        write_u32(output, version)
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
            if version in (3,5):write_memory(output, prepared.expected_ram_masks)
            write_u16(output, prepared.expected_event)
            write_u8(output, prepared.expected_retired)
            if version in (4,5):
                write_u32(output,len(prepared.expected_io))
                for direction,address,bhe,data in prepared.expected_io:
                    write_u8(output,direction);write_u32(output,address);write_u8(output,bhe);write_u16(output,data)


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
        reason = scope_exclusion(case, opcode, getattr(args, 'include_exceptions', False), getattr(args, 'include_prefixes', False))
        if reason is not None:
            exclusions.append({"index": case.index, "hash": case.test_hash, "reason": reason})
            if args.index == case.index or (args.test_hash is not None and args.test_hash.lower() == case.test_hash):
                raise SingleStepRunnerError(f"case {case.index}: requested case excluded: {reason}")
        else:
            eligible.append(case)
    selected, selection_skipped = select_cases(
        tuple(eligible), frozenset(), args.sample, args.full, args.index, args.test_hash
    )
    from tools.singlestep_admission import prepare_population
    selected, prepared, not_evaluable = prepare_population(
        selected, opcode, source_path,
        lambda case: prepare_case(case, opcode, getattr(args, 'include_exceptions', False), getattr(args, 'include_prefixes', False)))
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
    if len(matches) != 1 or sum(line.startswith('SINGLESTEP_RESULT') for line in result.stdout.splitlines()) != 1:
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
    if len(cases) != revoked_count + prefix_skipped + exception_skipped + selection_skipped + executed + len(not_evaluable):
        raise SingleStepRunnerError(f"SingleStep discovery accounting mismatch for {opcode}")
    report = {"opcode": opcode, "discovered": len(cases), "revoked": revoked_count,
              "prefix_skipped": prefix_skipped, "exception_skipped": exception_skipped,
              "selection_skipped": selection_skipped, "selected": len(prepared),
              "executed": executed, "passed": passed, "failed": failed, "exclusions": exclusions,
              "not_evaluable": not_evaluable,
              "inherited_selected":sum(opcode in INHERITED_OPCODES and c.exception is None for c in selected),
              "undefined_frame_flags_masked":sum(bool(c.expected_ram_masks) for c in prepared),
              "fault_selected":sum(opcode in INHERITED_OPCODES and c.exception is not None for c in selected),
              "phase6_selected":len(selected) if opcode in PHASE6_OPCODES else 0}
    if getattr(args, 'include_prefixes', False):
        identities = []
        for case in selected:
            legacy = opcode in INHERITED_OPCODES + PHASE6_OPCODES
            category = ('legacy_prefix' if case.instruction_bytes[0] in PREFIXES else 'legacy') if legacy else 'new_form'
            identities.append({'index':case.index,'hash':case.test_hash,'category':category})
        identity_path=build_dir/'singlestep'/'identities'/f'{opcode}.json'
        identity_path.parent.mkdir(parents=True,exist_ok=True)
        identity_bytes=(json.dumps(identities,sort_keys=True,separators=(',',':'))+'\n').encode()
        identity_path.write_bytes(identity_bytes)
        report['identity_sha256']=hashlib.sha256(identity_bytes).hexdigest()
        raw=source_path.read_bytes()
        report['source_git_blob']=hashlib.sha1(f'blob {len(raw)}\0'.encode()+raw).hexdigest()
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
    parser.add_argument("--all", action="store_true", help="select every supported file with prefixes and exceptions")
    parser.add_argument("--stack-control", action="store_true", help="select all stack and near-control forms")
    parser.add_argument('--events',action='store_true',help='select all nine interrupt/exception instruction files')
    parser.add_argument('--phase6',action='store_true',help='select all inherited/new families including real-mode faults')
    parser.add_argument('--include-prefixes',action='store_true',help='admit supported prefix contexts')
    parser.add_argument('--include-exceptions',action='store_true',help='admit inherited real-mode exception outcomes')
    parser.add_argument("--alu", action="store_true", help="select every admitted word ALU form")
    parser.add_argument("--full", action="store_true", help="run every non-revoked case")
    parser.add_argument("--sample", type=int, help="run this many deterministic cases per opcode")
    parser.add_argument("--smoke", action="store_true", help="run the fixed ten-case-per-opcode smoke sample")
    parser.add_argument("--index", type=int, help="run one test index; use with one --opcode")
    parser.add_argument("--hash", dest="test_hash", help="run one test hash; use with one --opcode")
    parser.add_argument("--trace", help="write a VCD; requires exactly one selected case")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.all:
        if args.opcodes or args.alu or args.stack_control or args.events or args.phase6:
            raise SingleStepRunnerError('--all cannot be combined with another family selector')
        args.opcodes = list(SUPPORTED_OPCODES)
        args.include_prefixes = args.include_exceptions = True
    if args.phase6 and args.include_prefixes:
        raise SingleStepRunnerError('--phase6 cannot admit prefixes')
    if args.events or args.phase6:
        if args.opcodes or args.alu or args.stack_control or (args.events and args.phase6):
            raise SingleStepRunnerError('incompatible event/family selectors')
        args.opcodes=list(INHERITED_OPCODES + PHASE6_OPCODES if args.phase6 else PHASE6_OPCODES)
        args.include_exceptions=True
    if args.stack_control:
        if args.opcodes or args.alu:
            raise SingleStepRunnerError('--stack-control cannot be combined with another family selector')
        args.opcodes = list(PHASE5_OPCODES)
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
