# Phase 6 portable capture probes

Status: **physical execution not run; all three evidence decisions unresolved**.
These are project-owned 80286 assembly experiments and preparation tools, outside
production RTL. They add no supported SPK286 instructions or timing profiles.

Read [the capture protocol](../../docs/PHASE6_CAPTURE_PROTOCOL.md) before using a
physical fixture. A generic binary is not a tested ArduinoX86 integration.
NASM and NDISASM are required only for these research payload checks. The existing
WSL installation supplies NASM 2.16.01; Python uses the standard library. CI and
the bootstrap package list explicitly install `nasm` (which includes NDISASM),
because ordinary regression discovers the mandatory probe tests.

From the WSL repository root, choose previously absent output directories:

```sh
python3 -m research.phase6_probes.build --output build/phase6-probes-capture
python3 -m research.phase6_probes.mechanics \
  --images build/phase6-probes-capture --output build/phase6-probes-mechanics
python3 -m unittest tests.test_phase6_probes -v
```

The build creates 21 configurations (12 A, 3 B, 6 C). Each contains `code.bin`,
`low.bin` (vectors/data), `stack.bin`, `reset.bin`, `config.json`, assembler
listing, disassembly, and `result.not-run.json`. `manifest.json` hashes every
artifact. Memory files are mapped by physical address in config; do not simply
concatenate them. The default byte outside mapped regions is CC. Compiled files
and captures belong in ignored storage, never in the source directory.

The mechanics interpreter actually reads and executes the generated instruction
bytes. It tests 18 **illustrative** combinations of alternative policies across
all configurations: 378 synthetic runs. It checks real instruction encodings,
stack room, first/second/third word failures, frames, marker order and finite
diagnostic stops. It does not model native timing, prefetch or READY; its
instruction-start trigger is simulation-only knowledge. It cannot adjudicate
hardware behavior. Its hypothetical `handler-step` retains live TF; other
mechanisms could produce a delayed #1 with a different saved FLAGS image.

The reset bootstrap uses real 286 segment-load/far-jump instructions, which are
outside the current SPK286 instruction subset. This is a physical fixture
payload, not a proposal to implement those instructions in Phase 6. No external
CPU core or reference implementation is imported by the mechanics interpreter.

See [RESULT_SCHEMA.md](RESULT_SCHEMA.md) for capture records. To inspect supplied
records and verify their raw hashes:

```sh
python3 -m research.phase6_probes.results --root /path/to/capture \
  /path/to/capture/records/*.json
python3 -m research.phase6_probes.results --require-physical \
  --root /path/to/capture /path/to/capture/records/*.json
```

The second command rejects not-run and simulation records. An exit zero means
record integrity only; it is never an architectural pass. The tool cannot prove
that someone truthfully labeled bytes as physical, validate unknown proprietary
trace formats, or replace independent inspection of setup, timing and controls.
No path here updates `docs/phase6_evidence.json`.

For the completed preparation work, retained results, independent review and
recovery snapshot, see [the closure dossier](../../docs/PHASE6_EVIDENCE_CLOSURE.md).
