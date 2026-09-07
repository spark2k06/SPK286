# SPK286 Microcode

The authoritative source is `source/*.mc`, compiled by
`tools/microcode/compile_microcode.py` using Python's standard library.
`SPK286_MICROCODE_FORMAT.md` defines the architecture; this file documents the
Phase 2.75 implementation subset.

```text
make microcode        # regenerate all five committed artifacts
make microcode-check  # byte comparison, no writes; stale output fails
make microcode-test   # independent compiler/ROM contract tests
```

## Language subset

Each source starts with `microcode_format 1`. Entries use uppercase snake case;
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

These are the only three executable statements. `TMP0` is a word temporary;
`DST` is the decoder's word-register metadata. Transfers preserve FLAGS.
`TMP0` must be defined before use in each entry. Every block ends in explicit
`END`; trailing operations and dangling labels are errors. Labels are debug
symbols, with no executable branch syntax in this subset. Conditional branches,
calls, additional operands, arithmetic, bus operands and timing annotations are
deferred and rejected, rather than silently accepted without implementation.

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

The initial encoding is two bits: 0 invalid, 1 fetch immediate word to TMP0,
2 transfer TMP0 to DST, 3 END. There are three used words and two address bits.
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

The decoder consumes B8..BF and latches `opcode[2:0]` as DST while loading the
generated entry. `spk286_microsequencer` owns micro-PC, entry and active state;
its ROM address output selects the generated ROM. The executor owns TMP0 and
the low/high byte progress bit. Completion advances the sequencer, while queue
starvation holds it. Each byte handshake advances architectural IP independently
of the BIU's fetch cursor. END retires exactly once after writeback.

Reset and valid redirects clear microstate and temporary acquisition. Execution
pauses hold them. Invalid ROM addresses/words halt with `microcode_fault` until
reset or cancellation. Debug PCs remain at the last operation when inactive;
consult `debug_micro_active` to distinguish a pending operation from a retired
one. Source strings are only in the generated map/listing and Python tools.

## Auditoría incorporada en Phase 2.80

`make microcode-audit` comprueba el contrato de Phase 2.75, la ROM RTL emitida
y su reconstrucción a DSL canónico. `make microcode-test` incluye los tests
del compilador y de esta auditoría. La regresión habitual ejecuta ambos.

El checker lee la plantilla concreta de package/case-ROM de encoding 1 y usa
los entry points y labels del JSON como metadatos: las palabras de dos bits
no contienen esos nombres. Reconstruye DSL, lo compila y compara las palabras,
direcciones y símbolos; los comentarios y las posiciones del fuente original
no forman parte del round-trip. No es un parser SystemVerilog general: primero
se exige la consistencia de los cinco artefactos con el compilador existente.

`tests/fixtures/microcode_phase2_75.json` fija `MOV_R16_IMM16=0`,
`MOV_R16_IMM16.writeback=1`, las palabras `[1, 2, 3]` y el ancho de dirección.
El test de desplazamiento añade otra entrada antes de MOV y demuestra que la
auditoría rechaza el cambio con ubicación de fuente. Una fase que amplíe la ISA
deberá versionar deliberadamente su contrato, conservando éste como evidencia
histórica; no se deben actualizar expectativas para ocultar una regresión.

Los informes ignorados `canonical.mc` y `audit.json` incluyen SHA-256 del fuente
y de los cinco artefactos. El compilador ya normalizaba CRLF/LF al leer archivos;
los nuevos tests comprueban esa propiedad y la independencia de `PYTHONHASHSEED`
en procesos separados. Los hashes de metadatos son del texto UTF-8 normalizado.
No se cambian el compilador de producción, el source MOV, el formato 1, el
encoding 1, el RTL ni los bytes de los cinco ficheros generados.
