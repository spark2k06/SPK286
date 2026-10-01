"""Audit encodings 1 through 27 using emitted RTL and canonical DSL reconstruction.

This is an offline checker for the existing generated case-ROM template, not a
general Verilog parser or a new production ROM format. Entry/label sidecars are
necessary because raw control words do not encode symbolic names or boundaries.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

from tools.microcode.compile_microcode import (
    CompileError, Location, ROOT, compile_sources, emit, encode, generate,
)

# Independent decoding of the documented encoding-1 wire representation.
STATEMENTS = {1: "FETCH_IMM16 -> TMP0", 2: "TMP0 -> DST", 3: "END",
              4: "DECODE_MODRM", 5: "READ_REG16 -> TMP0", 6: "READ_RM16 -> TMP0",
              7: "TMP0 -> REG16", 8: "TMP0 -> RM16",
              9: "READ_REG16 -> TMP1", 10: "READ_RM16 -> TMP1",
              11: "FETCH_IMM16 -> TMP1", 12: "FETCH_IMM8S -> TMP1",
              13: "READ_DST16 -> TMP0", 14: "ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED",
              15: "TMP2 -> REG16 IF_WRITE", 16: "TMP2 -> RM16 IF_WRITE",
              17: "TMP2 -> DST IF_WRITE", 18: "COMMIT_FLAGS", 19: "CHECK_RM16", 20: "FETCH_IMM8S -> TMP0",
              21: "PUSH16 DECODED TMP0", 22: "POP16 -> TMP0", 23: "READ_IP16 -> TMP0",
              24: "TARGET_REL16 TMP1", 25: "TARGET_ABS16 TMP0", 26: "REDIRECT DECODED",
              27: "ADJUST_SP16 TMP1", 28: "COUNT DECODED",
              29: 'FETCH_IMM8 -> TMP0', 30: 'READ_FLAGS -> TMP0', 31: 'RESTORE_FLAGS TMP0',
              32: 'SET_IF DECODED', 33: 'HALT', 34: 'REQUEST_EVENT DECODED', 35: 'EVENT_ACK',
              36: 'EVENT_FLAGS -> TMP0', 37: 'EVENT_CS -> TMP0', 38: 'EVENT_IP -> TMP0',
              39: 'CLEAR_IF_TF', 40: 'VECTOR_IP -> TMP0', 41: 'VECTOR_CS -> TMP1',
              42: 'CONTEXT_COMMIT TMP0 TMP1', 43: 'POP16 -> TMP1', 44: 'POP16 -> TMP2',
              45: 'IRET_COMMIT TMP0 TMP1 TMP2',
              46: 'READ_REG8 -> TMP0', 47: 'READ_RM8 -> TMP0', 48: 'TMP0 -> REG8', 49: 'TMP0 -> RM8',
              50: 'FETCH_IMM8 -> TMP1', 51: 'READ_REG8 -> TMP1', 52: 'READ_RM8 -> TMP1',
              53: 'READ_DST8 -> TMP0', 54: 'TMP0 -> DST8', 55: 'TMP2 -> REG8 IF_WRITE',
              56: 'TMP2 -> RM8 IF_WRITE', 57: 'TMP2 -> DST8 IF_WRITE',
              58: 'FLAGS DECODED', 59: 'SIGN_EXTEND8 TMP0', 60: 'SIGN_FILL16 TMP0', 61: 'CONST_ONE -> TMP1', 62: 'SHIFT DECODED TMP0 TMP1 -> TMP2 FLAGS_DECODED', 63: 'COUNT_LOW -> TMP1', 64: 'READ_EA -> TMP0', 65: 'TMP1 -> REG8', 66: 'TMP1 -> REG16', 67: 'READ_TARGET16 -> TMP1', 68: 'TMP1 -> SOURCE16', 69: 'SET_ADDRESS TMP1', 70: 'ADD_BASE TMP0 -> TMP1', 71: 'DISPATCH DECODED', 72: 'CONST_ZERO -> TMP1', 73: 'CONST_ONES -> TMP1', 74: 'ADJUST DECODED TMP0 TMP1 -> TMP2 FLAGS_DECODED', 75: 'CHECK_ARITHMETIC', 76: 'READ_SEG16 -> TMP0', 77: 'TMP0 -> SEG16'}

STATEMENTS.update({78: 'READ_AX -> TMP0', 79: 'READ_CX -> TMP0', 80: 'READ_DX -> TMP0', 81: 'READ_BX -> TMP0', 82: 'READ_SP -> TMP0', 83: 'READ_BP -> TMP0', 84: 'READ_SI -> TMP0', 85: 'READ_DI -> TMP0', 86: 'TMP0 -> AX', 87: 'TMP0 -> CX', 88: 'TMP0 -> DX', 89: 'TMP0 -> BX', 90: 'TMP0 -> SP', 91: 'TMP0 -> BP', 92: 'TMP0 -> SI', 93: 'TMP0 -> DI', 94: 'SAVE_AUX TMP0', 95: 'RESTORE_AUX -> TMP0', 96: 'SAVE_ALLOCATION TMP0', 97: 'LOAD_COUNTER TMP1', 98: 'DECREMENT_COUNTER', 99: 'BRANCH_ZERO', 100: 'BRANCH_NONZERO', 101: 'CHECK_PUSH8', 102: 'CHECK_POP8', 103: 'BEGIN_STACK_CURSOR', 104: 'CHECK_STACK TMP0', 105: 'SET_STACK_ADDRESS TMP0', 106: 'READ_STACK_ADDRESS -> TMP0', 107: 'DECREMENT_STACK_ADDRESS', 108: 'ALLOCATE_STACK', 109: 'CHECK_RM32', 110: 'SET_EA_PLUS2', 111: 'CHECK_BOUNDS', 112: 'READ_STACK_CURSOR -> TMP0'})
STATEMENTS.update({116: 'MULDIV8 DECODED TMP0', 117: 'MULDIV16 DECODED TMP0', 118: 'IMUL16 TMP0 TMP1', 119: 'RESULT_LOW -> AX', 120: 'RESULT_HIGH -> DX'})


def validate_entries(program, expected):
    for name, address in expected.items():
        if name not in program.entries:
            raise CompileError(Location("<entry-contract>", 1), f"missing required entry {name}")
        actual = program.entries[name]
        if actual != address:
            raise CompileError(program.operations[actual].location,
                               f"entry {name} moved: expected {address}, got {actual}")


STATEMENTS.update({113: 'CHECK_PUSH2', 114: 'CHECK_POP2', 115: 'ADD_ALLOCATION_SP'})


STATEMENTS.update({121: 'BRANCH_REPEAT_EMPTY', 122: 'STEP_STRING_SOURCE', 123: 'STEP_STRING_DEST', 124: 'REPEAT_COUNT', 125: 'READ_STRING_TMP0', 126: 'READ_STRING_TMP1', 127: 'WRITE_STRING_TMP0', 128: 'BRANCH_REPEAT_CONTINUE', 129: 'READ_STRING_ACCUMULATOR', 130: 'WRITE_STRING_ACCUMULATOR', 3: 'END', 14: 'ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED', 17: 'TMP2 -> DST IF_WRITE', 18: 'COMMIT_FLAGS'})


STATEMENTS.update({131: 'IO_READ8 TMP1 -> TMP0', 132: 'IO_READ16 TMP1 -> TMP0', 133: 'IO_WRITE8 TMP1 TMP0', 134: 'IO_WRITE16 TMP1 TMP0', 135: 'FETCH_PORT DECODED -> TMP1',
                   136: 'SYSTEM_STORE_GDTR', 137: 'SYSTEM_STORE_IDTR', 138: 'SYSTEM_LOAD_GDTR',
                   139: 'SYSTEM_LOAD_IDTR', 140: 'SYSTEM_STORE_MSW', 141: 'SYSTEM_LOAD_MSW',
                   142: 'SYSTEM_STORE_LDTR', 143: 'SYSTEM_STORE_TR', 144: 'SYSTEM_LOAD_LDTR',
                   145: 'SYSTEM_LOAD_TR', 146: 'SYSTEM_VERIFY_READ', 147: 'SYSTEM_VERIFY_WRITE',
                   148: 'SYSTEM_LOAD_ACCESS', 149: 'SYSTEM_LOAD_LIMIT', 150: 'VALIDATE_CS'})
STATEMENTS.update({166: 'SYSTEM_ARPL_CHECK', 167: 'SYSTEM_ARPL', 168: 'SYSTEM_CLTS', 169: 'TASK_SWITCH', 170: 'TASK_RETURN'})
STATEMENTS.update({171: 'LOADALL', 172: 'CARRY_FILL8 TMP0'})
STATEMENTS.update({193: 'CHECK_PROTECTED_MODE', 194: 'CHECK_SYSTEM_PRIVILEGE'})
STATEMENTS.update({195: 'CHECK_IO_PRIVILEGE'})
STATEMENTS.update({196: 'CHECK_NPX_ESC', 197: 'CHECK_NPX_WAIT'})
STATEMENTS.update({173: 'DECODE_ALU_RM16_REG16', 174: 'DECODE_ALU_REG16_RM16',
                   175: 'DECODE_ALU_RM8_REG8', 176: 'DECODE_ALU_REG8_RM8',
                   177: 'DECODE_MOV_RM16_REG16', 178: 'DECODE_MOV_REG16_RM16',
                   179: 'DECODE_MOV_RM8_REG8', 180: 'DECODE_MOV_REG8_RM8',
                   190: 'DECODE_UNARY_RM16', 191: 'DECODE_UNARY_RM8',
                   192: 'EXEC_INC_DEC_DST16'})
STATEMENTS.update({181: 'FETCH_ALU_DST16_IMM16', 182: 'FETCH_ALU_DST8_IMM8',
                   183: 'FETCH_ALU_RM16_IMM16', 184: 'FETCH_ALU_RM16_IMM8S',
                   185: 'FETCH_ALU_RM8_IMM8', 186: 'FETCH_MOV_DST16_IMM16',
                   187: 'FETCH_MOV_DST8_IMM8', 188: 'FETCH_MOV_RM16_IMM16',
                   189: 'FETCH_MOV_RM8_IMM8'})
STATEMENTS.update({151: 'VALIDATE_EVENT_GATE', 152: 'EVENT_GATE_IP -> TMP0',
                   153: 'EVENT_GATE_CS -> TMP1', 154: 'CLEAR_EVENT_FLAGS',
                   155: 'PUSH_EVENT_ERROR', 156: 'VALIDATE_IRET_CS',
                   157: 'IRET_OUTER_FRAME', 158: 'VALIDATE_IRET_SS',
                   159: 'VALIDATE_CALL_GATE', 160: 'VALIDATE_CALL_CS',
                   161: 'VALIDATE_CALL_STACK', 162: 'VALIDATE_CALL_SS',
                   163: 'CALL_GATE_STACK_SWITCH', 164: 'CHECK_CALL_FRAME',
                   165: 'COPY_CALL_PARAMETERS'})


def read_generated_words(package: str, rom: str) -> tuple[int, ...]:
    def dimension(name):
        matches = re.findall(rf"localparam integer {name} = ([0-9]+);", package)
        if len(matches) != 1:
            raise ValueError(f"expected one generated {name} declaration")
        return int(matches[0])

    depth = dimension("MC_DEPTH")
    width = dimension("MC_ADDR_WIDTH")
    word_width = dimension("MC_WORD_WIDTH")
    if word_width not in (2, 4, 5, 6, 7, 8) or not 1 <= width <= 12 or not 1 <= depth <= 1 << width:
        raise ValueError("invalid ROM dimensions")
    constants = re.findall(rf"MC_([A-Z0-9_]+) = {word_width}'d([0-9]+);", package)
    values = {}
    for name, value in constants:
        if name in values:
            raise ValueError(f"duplicate ROM constant {name}")
        values[name] = int(value)
    expected = {"INVALID": 0, "FETCH_IMM16": 1, "MOVE": 2, "END": 3}
    if word_width >= 4:
        expected.update(DECODE_MODRM=4, READ_REG16=5, READ_RM16=6, WRITE_REG16=7, WRITE_RM16=8)
    if word_width >= 5:
        expected.update(READ_REG16_TMP1=9, READ_RM16_TMP1=10, FETCH_IMM16_TMP1=11,
                        FETCH_IMM8S_TMP1=12, READ_DST16=13, ALU=14,
                        WRITE_RESULT_REG16=15, WRITE_RESULT_RM16=16,
                        WRITE_RESULT_DST=17, COMMIT_FLAGS=18)
    if dimension('MC_FORMAT_VERSION') >= 4:
        expected.update(CHECK_RM16=19, FETCH_IMM8S_TMP0=20, PUSH16=21, POP16=22,
                        READ_IP16=23, TARGET_REL16=24, TARGET_ABS16=25,
                        REDIRECT=26, ADJUST_SP16=27, COUNT=28)
    if dimension('MC_FORMAT_VERSION') >= 5:
        expected.update(FETCH_IMM8=29, READ_FLAGS=30, RESTORE_FLAGS=31, SET_IF=32,
                        HALT=33, REQUEST_EVENT=34, EVENT_ACK=35, EVENT_FLAGS=36,
                        EVENT_CS=37, EVENT_IP=38, CLEAR_IF_TF=39, VECTOR_IP=40,
                        VECTOR_CS=41, CONTEXT_COMMIT=42, POP16_TMP1=43,
                        POP16_TMP2=44, IRET_COMMIT=45)
    if dimension('MC_FORMAT_VERSION') >= 6:
        expected.update(READ_REG8=46, READ_RM8=47, WRITE_REG8=48, WRITE_RM8=49, FETCH_IMM8_TMP1=50,
                        READ_REG8_TMP1=51, READ_RM8_TMP1=52, READ_DST8=53, MOVE8=54,
                        WRITE_RESULT_REG8=55, WRITE_RESULT_RM8=56, WRITE_RESULT_DST8=57)
    if dimension('MC_FORMAT_VERSION') >= 7:
        expected.update(FLAGS_DECODED=58, SIGN_EXTEND8=59, SIGN_FILL16=60, CONST_ONE_TMP1=61)
    if dimension('MC_FORMAT_VERSION') >= 8:
        expected.update(SHIFT=62, COUNT_LOW_TMP1=63)
    if dimension('MC_FORMAT_VERSION') >= 9:
        expected.update(READ_EA=64, WRITE_REG8_TMP1=65, WRITE_REG16_TMP1=66, READ_TARGET16_TMP1=67, MOVE_SOURCE16_TMP1=68, SET_ADDRESS_TMP1=69, ADD_BASE_TMP0_TMP1=70)
    if dimension('MC_FORMAT_VERSION') >= 10:
        expected.update(DISPATCH_DECODED=71, CONST_ZERO_TMP1=72, CONST_ONES_TMP1=73)
    if dimension('MC_FORMAT_VERSION') >= 11:
        expected.update(ADJUST=74, CHECK_ARITHMETIC=75)
    if dimension('MC_FORMAT_VERSION') >= 12:
        expected.update(READ_SEG16_TMP0=76, WRITE_SEG16_TMP0=77)
    if dimension('MC_FORMAT_VERSION') >= 17:
        expected.update({'IO_READ8': 131, 'IO_READ16': 132, 'IO_WRITE8': 133, 'IO_WRITE16': 134, 'FETCH_PORT': 135,
                         'SYSTEM_STORE_GDTR': 136, 'SYSTEM_STORE_IDTR': 137, 'SYSTEM_LOAD_GDTR': 138,
                         'SYSTEM_LOAD_IDTR': 139, 'SYSTEM_STORE_MSW': 140, 'SYSTEM_LOAD_MSW': 141,
                         'SYSTEM_STORE_LDTR': 142, 'SYSTEM_STORE_TR': 143,
                         'SYSTEM_LOAD_LDTR': 144, 'SYSTEM_LOAD_TR': 145,
                         'SYSTEM_VERIFY_READ': 146, 'SYSTEM_VERIFY_WRITE': 147,
                         'SYSTEM_LOAD_ACCESS': 148, 'SYSTEM_LOAD_LIMIT': 149,
                         'VALIDATE_CS': 150})
    if dimension('MC_FORMAT_VERSION') >= 18:
        expected.update({'VALIDATE_EVENT_GATE': 151, 'EVENT_GATE_IP': 152,
                         'EVENT_GATE_CS': 153, 'CLEAR_EVENT_FLAGS': 154,
                         'PUSH_EVENT_ERROR': 155, 'VALIDATE_IRET_CS': 156,
                         'IRET_OUTER_FRAME': 157, 'VALIDATE_IRET_SS': 158,
                         'VALIDATE_CALL_GATE': 159, 'VALIDATE_CALL_CS': 160,
                         'VALIDATE_CALL_STACK': 161, 'VALIDATE_CALL_SS': 162,
                         'CALL_GATE_STACK_SWITCH': 163, 'CHECK_CALL_FRAME': 164,
                         'COPY_CALL_PARAMETERS': 165})
    if dimension('MC_FORMAT_VERSION') >= 20:
        expected.update({'SYSTEM_ARPL_CHECK': 166, 'SYSTEM_ARPL': 167, 'SYSTEM_CLTS': 168, 'TASK_SWITCH': 169, 'TASK_RETURN': 170})
    if dimension('MC_FORMAT_VERSION') >= 21:
        expected.update({'LOADALL': 171, 'CARRY_FILL8': 172})
    if dimension('MC_FORMAT_VERSION') >= 22:
        expected.update({'DECODE_ALU_RM16_REG16': 173, 'DECODE_ALU_REG16_RM16': 174,
                         'DECODE_ALU_RM8_REG8': 175, 'DECODE_ALU_REG8_RM8': 176,
                         'DECODE_MOV_RM16_REG16': 177, 'DECODE_MOV_REG16_RM16': 178,
                         'DECODE_MOV_RM8_REG8': 179, 'DECODE_MOV_REG8_RM8': 180,
                         'DECODE_UNARY_RM16': 190, 'DECODE_UNARY_RM8': 191,
                         'EXEC_INC_DEC_DST16': 192})
    if dimension('MC_FORMAT_VERSION') >= 23:
        expected.update({'FETCH_ALU_DST16_IMM16': 181, 'FETCH_ALU_DST8_IMM8': 182,
                         'FETCH_ALU_RM16_IMM16': 183, 'FETCH_ALU_RM16_IMM8S': 184,
                         'FETCH_ALU_RM8_IMM8': 185, 'FETCH_MOV_DST16_IMM16': 186,
                         'FETCH_MOV_DST8_IMM8': 187, 'FETCH_MOV_RM16_IMM16': 188,
                         'FETCH_MOV_RM8_IMM8': 189})
    if dimension('MC_FORMAT_VERSION') >= 24:
        expected.update({'CHECK_PROTECTED_MODE': 193, 'CHECK_SYSTEM_PRIVILEGE': 194})
    if dimension('MC_FORMAT_VERSION') >= 25:
        expected.update({'CHECK_IO_PRIVILEGE': 195})
    if dimension('MC_FORMAT_VERSION') >= 26:
        expected.update({'CHECK_NPX_ESC': 196, 'CHECK_NPX_WAIT': 197})
    if dimension('MC_FORMAT_VERSION') >= 16:
        expected.update({'BRANCH_REPEAT_EMPTY': 121, 'STEP_STRING_SOURCE': 122, 'STEP_STRING_DEST': 123, 'REPEAT_COUNT': 124, 'READ_STRING_TMP0': 125, 'READ_STRING_TMP1': 126, 'WRITE_STRING_TMP0': 127, 'BRANCH_REPEAT_CONTINUE': 128, 'READ_STRING_ACCUMULATOR': 129, 'WRITE_STRING_ACCUMULATOR': 130})
    if dimension('MC_FORMAT_VERSION') >= 14:
        expected.update({'CHECK_PUSH2':113,'CHECK_POP2':114,'ADD_ALLOCATION_SP':115})
    if dimension('MC_FORMAT_VERSION') >= 13:
        expected.update({'READ_AX_TMP0': 78, 'READ_CX_TMP0': 79, 'READ_DX_TMP0': 80, 'READ_BX_TMP0': 81, 'READ_SP_TMP0': 82, 'READ_BP_TMP0': 83, 'READ_SI_TMP0': 84, 'READ_DI_TMP0': 85, 'WRITE_AX_TMP0': 86, 'WRITE_CX_TMP0': 87, 'WRITE_DX_TMP0': 88, 'WRITE_BX_TMP0': 89, 'WRITE_SP_TMP0': 90, 'WRITE_BP_TMP0': 91, 'WRITE_SI_TMP0': 92, 'WRITE_DI_TMP0': 93, 'SAVE_AUX_TMP0': 94, 'RESTORE_AUX_TMP0': 95, 'SAVE_ALLOCATION_TMP0': 96, 'LOAD_COUNTER_TMP1': 97, 'DECREMENT_COUNTER': 98, 'BRANCH_ZERO': 99, 'BRANCH_NONZERO': 100, 'CHECK_PUSH8': 101, 'CHECK_POP8': 102, 'BEGIN_STACK_CURSOR': 103, 'CHECK_STACK_TMP0': 104, 'SET_STACK_ADDRESS_TMP0': 105, 'READ_STACK_ADDRESS_TMP0': 106, 'DECREMENT_STACK_ADDRESS': 107, 'ALLOCATE_STACK': 108, 'CHECK_RM32': 109, 'SET_EA_PLUS2': 110, 'CHECK_BOUNDS': 111, 'READ_STACK_CURSOR_TMP0': 112})
    if dimension('MC_FORMAT_VERSION') >= 15:
        expected.update({'MULDIV8': 116, 'MULDIV16': 117, 'IMUL_IMM16': 118, 'WRITE_RESULT_AX16': 119, 'WRITE_RESULT_DX16': 120})
    if {name: values.get(name) for name in expected} != expected:
        raise ValueError("unexpected encoding operation constants")
    words = [0] * depth
    seen = set()
    for bits, address, operation in re.findall(
            r"([0-9]+)'d([0-9]+): word = spk286_microcode_pkg::MC_([A-Z0-9_]+);", rom):
        address = int(address)
        if int(bits) != width or address >= depth:
            raise ValueError(f"ROM address {address} out of range or wrong width")
        if address in seen:
            raise ValueError(f"duplicate ROM address {address}")
        if operation not in expected or operation == "INVALID":
            raise ValueError(f"invalid ROM operation {operation} at {address}")
        seen.add(address)
        words[address] = values[operation]
    if not seen or sorted(seen) != list(range(len(seen))):
        raise ValueError("generated operations must have contiguous unique addresses")
    return tuple(words)


def read_generated_branches(package: str) -> dict[int, int]:
    entries = re.findall(r"([0-9]+)'d([0-9]+): micro_branch_target = \{1'b1, ([0-9]+)'d([0-9]+)\};",package)
    width=int(re.search(r'MC_ADDR_WIDTH = ([0-9]+);',package)[1])
    depth=int(re.search(r'MC_DEPTH = ([0-9]+);',package)[1])
    result={}
    for a,pc,b,target in entries:
        pc,target=int(pc),int(target)
        if int(a)!=width or int(b)!=width or pc in result or not 0<=pc<depth or not 0<=target<depth:
            raise ValueError('invalid generated branch target')
        result[pc]=target
    return result


def canonical_source(words, entries, labels=None, branch_targets=None):
    labels = {} if labels is None else labels
    branch_targets = {} if branch_targets is None else branch_targets
    if set(branch_targets) != {i for i,w in enumerate(words) if w in (99,100,121,128)}:
        raise ValueError("missing or extraneous branch target metadata")
    if not words or any(type(w) is not int or w not in (0, *STATEMENTS) for w in words):
        raise ValueError("invalid ROM words")
    used = len(words)
    while used and words[used - 1] == 0:
        used -= 1
    if not used or 0 in words[:used]:
        raise ValueError("invalid word within used ROM")
    by_address = {}
    for name, address in entries.items():
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
            raise ValueError(f"invalid entry name {name}")
        if type(address) is not int or not 0 <= address < used or address in by_address:
            raise ValueError(f"invalid or duplicate entry address {address}")
        if address and words[address - 1] not in (3, 71):
            raise ValueError(f"entry {name} is not at an END boundary")
        by_address[address] = name
    if 0 not in by_address:
        raise ValueError("missing entry at address 0")
    label_addresses = {}
    for symbol, address in sorted(labels.items()):
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)\.([a-z][a-z0-9_]*)", symbol)
        if not match or match[1] not in entries or type(address) is not int or not 0 <= address < used:
            raise ValueError(f"invalid label {symbol}")
        owner = by_address[max(a for a in by_address if a <= address)]
        if owner != match[1]:
            raise ValueError(f"label {symbol} outside its entry")
        label_addresses.setdefault(address, []).append(match[2])
    unary = any(tuple(words[i:i+7]) in ((4,47,61,14,56,18,3), (4,6,61,14,16,18,3)) for i in range(len(words)-6))
    version = 21 if any(w > 170 for w in words) else 20 if any(w > 164 for w in words) else 19 if any(w > 160 for w in words) else 18 if any(w > 150 for w in words) else 17 if any(w > 130 for w in words) else 16 if any(w > 120 for w in words) else 15 if any(w > 115 for w in words) else 14 if any(w > 112 for w in words) else 13 if any(w > 77 for w in words) else 12 if any(w > 75 for w in words) else 11 if any(w > 73 for w in words) else 10 if any(w > 70 for w in words) or unary else 9 if any(w > 63 for w in words) else 8 if any(w > 61 for w in words) else 7 if any(w > 57 for w in words) or any(tuple(words[i:i+2]) == (30, 54) for i in range(len(words)-1)) else 6 if any(w > 45 for w in words) else 5 if any(w > 28 for w in words) else (4 if any(w > 18 for w in words) else (3 if any(w > 8 for w in words) else (2 if any(w > 3 for w in words) else 1)))
    if any(w > 172 for w in words):
        version = 22
    if any(181 <= w <= 189 for w in words):
        version = 23
    if any(w in (193, 194) for w in words):
        version = 24
    if 195 in words:
        version = 25
    if any(w in (196, 197) for w in words):
        version = 26
    if any(tuple(words[pc:pc+4]) == (196, 4, 19, 3) for pc in entries.values()):
        version = 27
    lines = [f"microcode_format {version}"]
    for address, word in enumerate(words[:used]):
        if address in by_address:
            owner_entry=by_address[address]
            lines.append(f"instruction {by_address[address]}:")
        elif address and words[address - 1] in (3, 71):
            raise ValueError(f"missing entry after END at {address-1}")
        lines.extend(f"{label}:" for label in label_addresses.get(address, []))
        statement=STATEMENTS[word]
        if word in (99,100,121,128):
            target=branch_targets[address]
            candidates=[name for name,pc in labels.items() if pc==target and name.startswith(owner_entry + '.')]
            if not candidates:
                raise ValueError('branch target has no instruction-local label')
            statement += ' ' + sorted(candidates)[0].split('.')[1]
        lines.append(f"    {statement}")
    source = "\n".join(lines) + "\n"
    # Reuse semantic validation, including TMP0 lifetime and the terminal END.
    compile_sources({"canonical.mc": source}, rom_depth=len(words))
    return source


def audit(output_dir, contract_path):
    sources = {p.relative_to(ROOT / "microcode/source").as_posix(): p.read_text(encoding="utf-8")
               for p in (ROOT / "microcode/source").rglob("*.mc")}
    program = compile_sources(sources)
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
    validate_entries(program, contract["entries"])
    generated_dir = ROOT / "microcode/generated"
    if not emit(generate(program), generated_dir, check=True):
        raise ValueError("stale generated microcode")
    artifacts = {p.name: p.read_bytes() for p in generated_dir.iterdir() if p.is_file()}
    words = read_generated_words(artifacts["spk286_microcode_pkg.sv"].decode(),
                                 artifacts["spk286_microcode_rom.sv"].decode())
    symbols = json.loads(artifacts["spk286_microcode_symbols.json"])
    metadata = json.loads(artifacts["spk286_microcode_validation.json"])
    for field in ("format_version", "encoding_version", "word_width"):
        if field in contract and metadata[field] != contract[field]:
            raise ValueError(f"phase {field} contract changed")
    if (list(words) != contract["words"] or symbols["entries"] != contract["entries"]
            or symbols["labels"] != contract["labels"]
            or program.address_width != contract["address_width"]):
        raise ValueError("phase ROM/symbol contract changed")
    branches=read_generated_branches(artifacts['spk286_microcode_pkg.sv'].decode())
    if branches!=program.branch_targets or {str(k):v for k,v in branches.items()}!=symbols.get('branch_targets',{}):
        raise ValueError('source/RTL branch target mismatch')
    if {str(k):v for k,v in branches.items()}!=contract.get('branch_targets',{}):
        raise ValueError('independent branch target contract changed')
    canonical = canonical_source(words, symbols["entries"], symbols["labels"],branches)
    reconstructed = compile_sources({"canonical.mc": canonical},
                                    address_width=program.address_width, rom_depth=program.depth)
    roundtrip_words = read_generated_words(generate(reconstructed)["spk286_microcode_pkg.sv"],
                                          generate(reconstructed)["spk286_microcode_rom.sv"])
    if words != roundtrip_words or list(words) != [encode(op) for op in program.operations]:
        raise ValueError("source/RTL/round-trip word mismatch")
    if program.entries != reconstructed.entries or program.labels != reconstructed.labels or program.branch_targets != reconstructed.branch_targets:
        raise ValueError("round-trip symbol mismatch")
    report = {"schema_version": 1, "validation": "PASS", "roundtrip": "PASS",
              "baseline": contract["baseline"], "entries": program.entries,
              "words": words, "source_sha256": program.source_hashes,
              "artifact_sha256": {name: hashlib.sha256(data).hexdigest()
                                  for name, data in sorted(artifacts.items())}}
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "canonical.mc").write_bytes(canonical.encode())
    (output_dir / "audit.json").write_bytes((json.dumps(report, sort_keys=True, indent=2)+"\n").encode())
    print("MICROCODE AUDIT PASS: phase entries, emitted ROM, source coupling and round-trip")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/microcode-audit")
    parser.add_argument("--contract", type=Path,
                        default=ROOT / "tests/fixtures/microcode_esc_boundary.json")
    args = parser.parse_args()
    audit(args.output, args.contract)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, UnicodeError) as error:
        print(f"MICROCODE AUDIT ERROR: {error}", file=sys.stderr)
        sys.exit(2)
