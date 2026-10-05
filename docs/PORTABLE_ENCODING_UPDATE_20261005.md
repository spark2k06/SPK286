# Portable encoding and length-boundary update — 2026-10-05

The CPU now suppresses a stale byte-eleven demand while a legal ten-byte
instruction is completing. A real eleven-byte encoding still raises #GP at
the first prefix. The portable public-interface unit runs READY waits 0..3
and event-boundary cases; its old-CPU negative control reproduces the defect.

Canonical microcode acquisition metadata and optional syntax-only decoder
leaves provide an encoding preview without another opcode map. Default
functional decoder/group entries and microcode words are unchanged. The
preview has no architectural side-effect interface.

Validation of these exact portable inputs is archived by PCAT-286 in the
2026-10-05 encoding-preview, length-fault-boundary and CPU-focused packets:
3,110 preview cases and 49,152 decoder combinations in each simulator;
10 public CPU length cases / 1,097 checks in each simulator; strict lint,
dual reset/state smoke, 470 stack/control SingleStep samples and Yosys PASS.
Four syntax Python tests, regeneration consistency and strict CPU/preview
lint also pass in this standalone checkout after synchronization.

The user explicitly deferred the full regression; no full-regression or
architectural release PASS is claimed. Existing unrelated historical test
adapter migrations are not part of this portable update. The two new banks
and preview lint/Python checks are registered in the existing standard paths.

No PC/AT chipset, MiSTer OSD, memory bridge or downstream profile scheduler
was copied into this CPU-only repository.
