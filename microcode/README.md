# SPK286 Microcode

The authoritative source is `source/*.mc`, compiled by
`tools/microcode/compile_microcode.py` using Python's standard library.
`SPK286_MICROCODE_FORMAT.md` defines the architecture; this file documents the
preserved Phase 2.75/3 formats and the active Phase 4 extension below.

```text
make microcode        # regenerate all five committed artifacts
make microcode-check  # byte comparison, no writes; stale output fails
make microcode-test   # independent compiler/ROM contract tests
```

## Language subset

Each source starts with `microcode_format 1` or `microcode_format 2`.
The production operand programs require format 2. Entries use uppercase snake case;
local debug labels use lowercase snake case and name the following operation.
Comments start with `#`. Whitespace/indentation is not semantic.

```text
microcode_format 1
instruction MOV_R16_IMM16:
    FETCH_IMM16 -> TMP0
writeback:
    TMP0 -> DST
    END
```

These are the three executable statements in format 1. `TMP0` is a word temporary;
`DST` is the decoder's word-register metadata. Transfers preserve FLAGS.
`TMP0` must be defined before use in each entry. Every block ends in explicit
`END`; trailing operations and dangling labels are errors. Labels are debug
symbols, with no executable branch syntax in this subset. Conditional branches,
calls, arithmetic and timing annotations are
deferred and rejected, rather than silently accepted without implementation.

Format 2 adds only the reusable operand acquisition and transfer operations:

```text
microcode_format 2
instruction MOV_RM16_R16:
    DECODE_MODRM
    READ_REG16 -> TMP0
writeback:
    TMP0 -> RM16
    END

instruction MOV_R16_RM16:
    DECODE_MODRM
    READ_RM16 -> TMP0
writeback:
    TMP0 -> REG16
    END
```

DECODE_MODRM must precede REG16/RM16 operations and cannot be repeated within
an entry. It consumes the required bytes and captures operand context. REG16
means the ModR/M reg field; RM16 means either its register or segmented memory
operand. Read operations define TMP0, and writes require a defined TMP0.
Format 1 rejects these operations. No physical bus states, EA table, segment
rules or delays are encoded in the source. All paths retire through END.

## Compiler and artifacts

The pipeline parses `Location`, `Statement`, `Label` and `Block` dataclasses,
resolves entries/labels, validates operands and temporary lifetime, expands to
addressed `MicroOp` records in a `Program`, then encodes operations. Each current
statement expands one-to-one. The functional word-fetch executor performs
the required two byte handshakes; source need not encode byte wait states.

Files are sorted by relative POSIX path, then entries retain source order.
Labels are scoped as `ENTRY.label`. No timestamp or absolute path enters output.
Address width and depth default to the minimum required; CLI limits can be
specified using `--address-width` and `--rom-depth`. The current debug interface
allows up to 12 address bits; overflow is an error.

All five files in `generated/` are committed, including the generated RTL.
They are distributable CPU inputs and must never be manually edited:

- `spk286_microcode_pkg.sv`: dimensions, control constants and entry constants.
- `spk286_microcode_rom.sv`: portable combinational ROM with validity output.
- `spk286_microcode.lst`: symbolic listing with source locations and words.
- `spk286_microcode_symbols.json`: schema 1, entries, scoped labels and per-PC
  operation/operand/source/word mappings.
- `spk286_microcode_validation.json`: schema/compiler/format/encoding versions,
  source SHA-256, dimensions, usage, warnings and validation status.

Format 1 retains encoding 1: two bits, 0 invalid, 1 fetch immediate word to TMP0,
2 transfer TMP0 to DST, 3 END. Format 2 uses encoding 2, four control bits:

| Word | Functional operation |
| --- | --- |
| 0 | INVALID |
| 1 | FETCH_IMM16 |
| 2 | MOVE TMP0 to DST |
| 3 | END |
| 4 | DECODE_MODRM |
| 5 | READ_REG16 to TMP0 |
| 6 | READ_RM16 to TMP0 |
| 7 | WRITE_REG16 from TMP0 |
| 8 | WRITE_RM16 from TMP0 |

The preserved Phase 3 ROM has depth 11 and four address bits; addresses 11..15 are invalid.
Entries are
MOV_R16_IMM16=0, MOV_RM16_R16=3, MOV_R16_RM16=7. Immediate MOV keeps words
[1,2,3] at its original addresses. The highest input format selects output
encoding, so historical format 1 sources still compile independently.
The ROM uses a complete combinational `case` with invalid default; no vendor
primitive or external initialization file is required. Synthesis may implement
this tiny ROM as logic. It is not claimed to infer block RAM.

Example symbol query:

```text
python3 -m tools.microcode.compile_microcode --lookup MOV_R16_IMM16.writeback
python3 -m tools.microcode.compile_microcode --pc 0x1
```

Numeric PCs index `operations` in the JSON map. Source locations use paths
relative to `microcode/source/`. Local label names do not consume ROM words.
Expected source errors report file, line and entry without a Python traceback.

Generation only rewrites changed files. `--check` compares all five byte streams
without repairing stale files. Every build/lint/synthesis entry script checks
consistency through `scripts/rtl_sources.sh`, also used as the ordered RTL
manifest. The generated package precedes the ROM and consumers. Compiler
tests also verify every artifact against the authoritative checked-in source.

Functional operation count is implementation scheduling, not historical 80286
timing. No timing fields, scheduler, cycle padding or idle operations exist.
Future metadata can extend the IR and versioned output without changing the
meaning of existing source statements.

## Execution contract

The decoder consumes B8..BF, 89 or 8B and loads the generated entry. Immediate
MOV latches `opcode[2:0]` as DST. `spk286_microsequencer` owns micro-PC, entry and active state;
its ROM address output selects the generated ROM. The executor owns TMP0 and
the low/high byte progress bit. Completion advances the sequencer, while queue
starvation holds it. For operand operations, the streaming context service
holds acquisition progress and the logical operand service holds a submitted
memory request until BIU response acceptance. Pausing preserves pending state
and held responses; no repeated request or write is permitted. The generic
microsequencer RTL is unchanged in Phase 3. Each byte handshake advances architectural IP independently
of the BIU's fetch cursor. END retires exactly once after writeback.

Reset and valid redirects clear microstate and temporary acquisition. Execution
pauses hold them. Invalid ROM addresses/words halt with `microcode_fault` until
reset or cancellation. Debug PCs remain at the last operation when inactive;
consult `debug_micro_active` to distinguish a pending operation from a retired
one. Source strings are only in the generated map/listing and Python tools.

## Independent contract and round-trip audit

`make microcode-audit` checks the active phase contract, emitted RTL and its
reconstruction to canonical DSL. It reads the compiler's package/case-ROM
template for encodings 1 and 2, using JSON entry/label metadata because names
are not encoded in ROM words. Recompilation must preserve words, addresses and
symbols; comments and original source positions are outside the round-trip.
This is not a general SystemVerilog parser. The five-artifact consistency check
remains a prerequisite.

`tests/fixtures/microcode_phase2_75.json` is unchanged historical evidence:
entry=0, writeback=1, words=[1,2,3] and the original address width. Tests compile
the frozen historical source and retain displacement/corruption rejection.
`tests/fixtures/microcode_phase3.json` deliberately versions the active contract:
format 2, encoding 2, four-bit control, three entries, labels and eleven words.
The auditor rejects mismatched versions, operation constants, symbols or words.
No expected hardware state is changed by this versioning.

Ignored `canonical.mc` and `audit.json` reports include source/artifact SHA-256.
Tests preserve CRLF/LF equivalence and independence of PYTHONHASHSEED across
processes. Metadata hashes describe normalized UTF-8 source. Compiler version
2.0 identifies the minimal operand extension; generated outputs remain entirely
owned by the compiler.

## Active Phase 4 format 3

Format/encoding 3 adds only ten controls, keeping all format-2 controls and MOV
entries unchanged. The current package uses five control bits, six address bits
and 45 used ROM words; addresses 45..63 are invalid. Compiler version is 3.0.
The active contract is tests/fixtures/microcode_phase4.json. The immutable
Phase 3 fixture is checked using frozen microcode_phase3.mc; format 1 remains
independently checked. No hardware-vector expected state is changed by versioning.

| Word | Source statement / meaning |
| --- | --- |
| 9 | READ_REG16 -> TMP1 |
| 10 | READ_RM16 -> TMP1 |
| 11 | FETCH_IMM16 -> TMP1 |
| 12 | FETCH_IMM8S -> TMP1 (sign extended) |
| 13 | READ_DST16 -> TMP0 |
| 14 | ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED |
| 15 | TMP2 -> REG16 IF_WRITE |
| 16 | TMP2 -> RM16 IF_WRITE |
| 17 | TMP2 -> DST IF_WRITE |
| 18 | COMMIT_FLAGS |

DECODED is an explicit compiler-validated selector for stable instruction
semantic metadata from spk286_alu_decode: functional ALU operation, write
permission, defined and undefined FLAGS masks. It is not a second opcode
decoder in the executor or sequencer. FLAGS_DECODED declares candidate-mask
policy without committing architectural FLAGS. Static ALU selectors and other
mask policies are not silently accepted. Source syntax, operation encoding,
source locations and canonical round-trip remain coupled and deterministic.

Five shared entries in word_alu.mc are ALU_RM16_R16=11, ALU_R16_RM16=18,
ALU_AX_IMM16=25, ALU_RM16_IMM16=31 and ALU_RM16_IMM8S=38. TMP0 is always A,
TMP1 always B and TMP2 the result. CMP uses decoded SUB and IF_WRITE=false.
The disposition operation then discards the result without an operand request.
This explicit semantic step is not historical latency padding.

The compiler rejects undefined temporaries, missing/duplicate context, invalid
ALU/FLAGS selectors, illegal destination, pending-result overwrite, repeated
result disposition, FLAGS before result disposition, missing FLAGS commit,
work after commit and work after END. Earlier formats reject the extensions.
COMMIT_FLAGS follows full register/logical-memory completion; END follows FLAGS.
The executor holds candidates/validity separately from architectural storage.
Pause holds all semantic state; reset/redirect/start clear new temporary and
candidate state. The generic microsequencer, BIU and operand service are unchanged.
