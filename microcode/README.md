# SPK286 Microcode

The authoritative source is `source/*.mc`, compiled by
`tools/microcode/compile_microcode.py` using Python's standard library.
`SPK286_MICROCODE_FORMAT.md` defines the architecture; this file documents the
preserved formats and incremental extensions. Format 22 adds register-direct
ALU/MOV execution; format 23 extends the atomic register commit to immediate
operands while retaining the validated memory sequence. See
[`REGISTER_EXECUTION_OPTIMIZATION.md`](../docs/REGISTER_EXECUTION_OPTIMIZATION.md)
and [`IMMEDIATE_EXECUTION_OPTIMIZATION.md`](../docs/IMMEDIATE_EXECUTION_OPTIMIZATION.md).

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

## Preserved Phase 4 format 3

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

## Phase 5 active image

`source/word_stack_control.mc` adds twelve reusable entries for register,
immediate and RM stack transfers, near CALL/RET/JMP, Jcc and LOOP/JCXZ.
Compiler/encoding 4 uses 97 five-bit words and seven-bit addresses. The first
45 words are preserved exactly. `tests/fixtures/microcode_phase5.json` is the
independently specified active contract; Phase 4 remains a frozen test.
The operation/lifetime contract is documented in
[SPK286_MICROCODE_FORMAT.md](../SPK286_MICROCODE_FORMAT.md). Generated files
must still be regenerated, never hand-edited. `make phase5-check` verifies
regeneration, all inherited gates and the stack/control additions.

## Phase 6 candidate active image

Compiler 5.0 / format 5 uses 28 entries, 128 words, seven-bit addresses and
six-bit controls. `z_interrupts.mc` is authoritative for shared event entry,
return and supporting FLAGS/IF/halt instructions. The sequencer remains generic.
Controls request functional operations and wait for real operand/BIU dependencies.

Format 4 sources are frozen in `tests/fixtures/microcode_phase5_sources.json`;
formats 1–4 remain tested. Active Phase 5 POP-memory loses CHECK_RM16 before its
POP, because physical destination-fault cases require the completed SP+2 effect.
The active image has an independent fixed-number fixture and canonical round-trip
checks. No generated artifact is edited by hand.

New event protocols validate ordered saved-state acquisition, temporary validity,
vector context, one final context commit and terminal END. Entry completion is
filtered from ordinary guest retirement. See [format](../SPK286_MICROCODE_FORMAT.md)
and [event contract](../docs/INTERRUPTS_EXCEPTIONS.md).

## Phase 7 byte/prefix increment (verified prior image)

The sections above describe historical images. Compiler 6.0 / format 6 now
uses 37 entries, 174 words, eight-bit addresses and six-bit controls.
`source/zz_byte_scalar.mc` adds nine reusable entries for byte MOV/ALU and
immediate-to-RM MOV. Controls 46–57 express typed byte operations; the
microsequencer remains generic. The two immediate RM word-ALU entries now
acquire their immediate bytes before requesting data memory, preserving the
physical overlength-fault ordering.

Frozen format 1–5 fixtures and source snapshots remain unchanged. The current
independent contract is `tests/fixtures/microcode_phase7_byte.json`, including
the two justified word-entry reorderings. The compiler checks byte operand,
temporary and result/FLAGS disposition protocols and rejects incompatible
word/event controls. Generate all artifacts from the .mc sources.

This is the bounded increment described in
[PHASE7_HANDOFF](../docs/PHASE7_HANDOFF.md), not the complete Phase 7 image.
The isolated 190-word scalar-I/O prototype is outside this source tree.

## Verified prior Phase 7 scalar increment

Compiler 7.0 / format 7 uses 42 entries, 193 words, eight-bit addresses and
six-bit controls. `source/zzz_scalar.mc` adds direct flag control, flags-to-byte,
byte sign extension, sign fill, and INC/DEC register protocols. Controls 58–61
are FLAGS_DECODED, SIGN_EXTEND8, SIGN_FILL16 and CONST_ONE_TMP1. Decode supplies
source/destination register selectors and the direct flag mask/data; the executor
never decodes guest opcodes. TEST reuses existing byte/word ALU microprograms
with decoded AND and suppressed result writeback.

Format 1–6 source snapshots and encoding fixtures stay frozen. The active
independent contract is `tests/fixtures/microcode_phase7_scalar.json`. Scalar
validation rejects undefined sources, missing result/FLAGS disposition, duplicate
commits and unsupported mixed protocols. The two register selectors are captured
at dispatch so CWD reads AX and writes DX through the existing GPR owner.
No control represents a historical timing delay. The separate I/O prototype
predates these control assignments and must be rebased through source/compiler
regeneration before integration. Its generated artifacts cannot be copied here.

## Verified prior format 8 shift extension

Controls 62 SHIFT and 63 COUNT_LOW_TMP1 retain six-bit words. Six symbolic
programs acquire ModR/M, then a constant/CL/immediate count, then the byte/word
operand. SHIFT produces TMP2, a precise FLAGS mask and a result disposition;
the existing conditional result operation precedes COMMIT_FLAGS and END.
COUNT_LOW snapshots the architectural count register's low byte before an
aliased operand is read. The arithmetic service owns iterative computation and
backpressure; the microsequencer waits for its real completion.

The active image has 48 entries/235 words, eight-bit addresses and six-bit
controls. The prior 193 words are unchanged. Frozen format-7 sources and the
independent format-8 fixture preserve historical and current encoding checks.
Count zero still reads/checks memory but suppresses result and FLAGS writes.
See docs/PHASE7_SHIFT_FLAGS.md for undefined flag policy and physical evidence.

## Verified prior format 9 data-transfer extension

Seven typed controls (64–70) acquire EA, write TMP1 to REG8/REG16, read the
decoded target, write the decoded source, set a temporary address, and add a
base to TMP0. The shared operand/register/BIU owners perform the actual effects.
Nine programs implement LEA, RM and accumulator XCHG, direct-offset MOV and
XLAT. Complete width/acquisition/commit protocols are required by the compiler.

The active image has 57 entries/282 words, nine-bit addresses and seven-bit
controls. All previous 235 words remain unchanged. Format-8 sources are frozen
in `microcode_phase7_shift_sources.json`; `microcode_phase7_data.json` supplies
the independent active encoding contract. Historical formats remain supported.
See `docs/PHASE7_DATA_TRANSFER.md` for address lifetime and partial commit rules.

## Verified prior format 10 unary and decoded dispatch extension

DISPATCH_DECODED (71) is a terminal micro-operation after DECODE_MODRM. The
existing instruction metadata decoder supplies a symbolic target; the generic
sequencer validates and follows it without resetting instruction state or
retiring. Targets query the operand decoder's explicitly rearmed cached context.
This consumes no extra bytes and does not recompute the effective address.

CONST_ZERO_TMP1 (72) and CONST_ONES_TMP1 (73) provide real ALU operands. Six
byte/word NOT, NEG and memory INC/DEC protocols require source acquisition,
ALU computation, result disposition, FLAGS commit and END. NOT uses complement
with an empty mask; NEG uses decoded operand reversal; INC/DEC preserve CF.
Two group dispatch entries preserve reusable TEST and near-control targets.

The image has 65 entries/328 words, nine-bit addresses and seven-bit controls.
All prior 282 words and entry addresses are unchanged. Format-9 sources are
frozen in microcode_phase7_data_sources.json and an independent 46-word literal
appendix specifies format 10. Parsing supports a multi-digit version. Canonical
reconstruction recognizes terminal dispatch and standalone memory INC/DEC using
older control values. Complete protocols and active CLI defaults are checked.
No branch or operation represents a historical timing delay.

## Active format 11 decimal and radix adjustments

ADJUST (74) requests the captured arithmetic service; CHECK_ARITHMETIC (75)
serializes a pending #DE before normal END. The direct and immediate-radix
programs each require complete acquisition, computation, result disposition,
FLAGS commit and fault check. AAM radix zero suppresses AX and commits the
physical fault FLAGS policy before the existing event owner captures the frame.
The image has 67 entries/342 words with nine address and seven control bits;
all prior 328 words and entry addresses remain unchanged. Frozen format-10
sources and the independent format-11 literal fixture check both contracts.
No microinstruction represents an idle delay or duplicates opcode decoding.
See docs/PHASE7_DECIMAL_ADJUST.md for arithmetic, exception and lifetime rules.

## Active format 12 segment transfers

READ_SEG16_TMP0 (76) and WRITE_SEG16_TMP0 (77) transfer a decoded architectural
selector through the existing temporary and sole segment/cache owner. The
source index comes from captured opcode/ModR/M metadata, independently of EA
segment selection. The four programs are MOV_RM16_SEG, MOV_SEG_RM16, PUSH_SEG
and POP_SEG. Source completion precedes cache write; POP commits old-stack
SP before loading the new selector. The generated image has 71 entries and
356 words; all 342 previous words are preserved. The compiler rejects incomplete
segment transfer protocols. SS inhibition belongs to the event owner, not to
microcode delays. See PHASE7_SEGMENT_TRANSFER.md and D-033.

## Active format 13 stack/frame and bounds programs

Five explicit programs express PUSHA, POPA, ENTER, LEAVE and BOUND. Generic
register transfers, auxiliary/allocation temporaries and a five-bit counter
support the frame loop; generated instruction-local branch targets carry an
explicit valid bit. The existing microsequencer owns and validates branches.
The image has 76 entries/433 words, nine address bits and seven control bits;
all 356 prior words and entry addresses are preserved. ENTER uses a transient
stack cursor and per-transfer checks: a fault preserves original architectural
SP/BP while retaining accepted memory writes. BOUND checks both modular word
starts and permits the physically observed FFFE-to-0000 even wrap. See D-034
and PHASE7_STACK_FRAME.md for sources and independent literal contracts.

## Active format 14 far pointer and context transfers

CHECK_PUSH2 (113) and CHECK_POP2 (114) validate the full four-byte return frame;
ADD_ALLOCATION_SP (115) applies RETF's unsigned immediate allocation. Seven
complete source protocols express LDS/LES, direct/memory far CALL and JMP, and
RETF with or without allocation. Both words precede pointer installation, and
CALL acquires a memory pointer before creating its return link. Context commit
uses the existing CS:IP owner and flush path. FLAGS and NMI blocking are unchanged.
The image has 83 entries/492 words, nine-bit addresses and seven-bit controls.
All 433 prior words, entries and frame-loop destinations remain stable. Frozen
format-13 sources and the independent literal format-14 fixture prevent silent
encoding or protocol drift. The separate arithmetic prototype must rebase its
human-readable source before integration because its tentative controls conflict.
See PHASE7_FAR_TRANSFERS.md for physical evidence and precise fault/lifecycle rules.

## Active format 15 integer arithmetic programs

Controls 116..120 describe byte/word implicit multiplication/division, immediate
signed multiplication and low/high result disposal. Four complete protocols
append 29 words to the delivered 492-word far image. The current image has
87 entries, 521 words, ten-bit addresses and seven-bit controls. Every previous
entry, control value and loop destination remains unchanged. Frozen format-14
sources and an independent literal format-15 fixture protect that boundary.
The arithmetic service captures operands, honors pause/cancel and produces one
response; microcode disposes results and FLAGS before publishing a divide
exception. The BIU owns operand access. No historical timing claim is made.
See docs/PHASE7_IDIV_COMPATIBILITY.md for the negative byte-overflow rule.

## String integration after arithmetic - format 16

The arithmetic format-15 image remains a frozen 521-word contract. Five string
protocols append 43 words and controls 121..130. The new active image has 92
entries / 564 words / ten-bit addresses / eight-bit controls. Its human source
is zzzzzzzzzzzz_strings.mc; generated artifacts must be regenerated normally.

## Current ordered integration candidate - 2026-09-09

This isolated candidate contains all 307 required opcode files but has not been
validated as a complete Phase 7 delivery. It preserves the arithmetic format-15
source and independent literal, followed by the string format-16 source and
literal. I/O is appended in format 17: 100 entries, 612 words, ten address and
eight control bits. Arithmetic controls remain 116..120, strings 121..130 and
I/O occupies 131..135. All generated artifacts come from human-readable source.

The functional RTL matches the separately tested complete candidate, whose
full regression passed and whose strict physical run failed preparation of E7.
Those older results do not establish this newly ordered image's execution.
The new image passed 254 ordinary tests, 88 compiler tests, independent active
and frozen literal/round-trip audits, lint and both-simulator decoder checks.
Fresh affected instruction tests, physical coverage, mutation audits and complete
regression are recorded separately as they actually finish.

The required E7 record c56d37647cc2dbcce82ca640fdd25ddea1f3ee5e is still not revoked
upstream. Its missing captured write strobe/data are not reconstructed from AX.
No original expected values, captures or revocation policy have been changed.
The original Phase 6 D-026 evidence questions remain open. New REP event evidence
and independent review remain pending; no new waiver or Phase 8 work is claimed.

See PHASE7_REP_EVENT_EVIDENCE.md and PHASE7_IO_CAPTURE_REVIEW.md for evidence
limitations. Complete Phase 7 remains incomplete; this directory is not a
verified Git delivery.

## Protected system access checks — format 24, 2026-09-30

H01 adds controls 193 (`CHECK_PROTECTED_MODE`) and 194
(`CHECK_SYSTEM_PRIVILEGE`). The H01 milestone image has 122 entries / 731 words,
ten address bits and eight control bits. LLDT/LTR check protected mode and
CPL0 before reading the selector operand. SLDT/STR, VERR/VERW and LAR/LSL check
protected mode before their operand side effects. These are semantic checks,
not timing padding. Existing compiler formats and their frozen literals remain
supported. The independent format-24 fixture is `microcode_system_access.json`,
derived by inserting exactly eight controls into the frozen format-23 image.
See `docs/PROTECTED_MODE_TARGETED_FIXES_20260930.md` for bounded verification.

## I/O privilege checks — format 25, 2026-09-30

H02's CLI/STI and I/O subset adds control 195 (`CHECK_IO_PRIVILEGE`). The active
image has 122 entries / 739 words, ten address bits and eight control bits.
Scalar and string I/O check CPL versus IOPL immediately after capturing the
port, before any port or memory transaction or count/index change. The string
loop label follows the check, so resuming an iteration preserves its existing
protocol. The existing zero-count REP branch remains before the check; its
protected-mode privilege precedence is explicitly outside this milestone.
CLI/STI check privilege at their existing IF operation and need no ROM change.

The independent active fixture is `microcode_iopl_access.json`, derived from
the frozen format-24 image by exactly eight check insertions, with explicitly
shifted labels and branch targets. Compiler validation rejects omitted, late,
duplicate or iteration-local checks. Historical fixtures remain frozen.
See `docs/PROTECTED_MODE_TARGETED_FIXES_20260930.md` for directed results and
the remaining H02 LOCK / zero-count REP questions.
