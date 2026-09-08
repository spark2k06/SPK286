# Capture record schema 1

The normative executable validator is `results.py`. JSON must not contain
duplicate keys, nonfinite numbers, unknown top-level fields or missing required
fields. UTF-8 records contain exactly these top-level keys:

| Field | Meaning |
|---|---|
| `schema` | Integer 1 |
| `id` | Unique capture identity, including repeat/sweep position |
| `test_id` | One of the 21 build IDs, or a source ID for a primary document |
| `provenance` | `physical`, `primary-document`, `simulation`, `not-run` |
| `status` | Respectively `captured`, `examined`, `completed`, `not-run` |
| `source` | Primary document metadata or null |
| `cpu` | Physical part metadata or null |
| `fixture` | Fixture/simulator identity and observation contract, or null |
| `initial` | Pre-measurement state/memory identity, or null |
| `stimulus` | Ordered pin stimulus records, or null for unexecuted/document records |
| `observation` | Observed data and interpretation, or null |
| `controls` | Array of IDs of independently retained repeat/control records |
| `raw_artifacts` | Array of `{kind, path, sha256}` descriptors |

`not-run` has null source/cpu/fixture/initial/stimulus/observation and empty
controls/artifacts. It is missing evidence, even when the payload assembled.
Generated mechanics reports have their own clearly labeled simulation report
format; they are not physical-capture records and fail this capture schema.

Every artifact path is relative to the supplied capture root. Absolute paths,
parent traversal, Windows drive/backslash paths, symlinks escaping the root,
duplicate paths, empty files, missing files and mismatched SHA-256 are rejected.
Keep the original instrument export, not just a derived human summary. Hashes
are lowercase 64-digit hex of exact bytes, not normalized text.

For an execution record, `initial` contains all fourteen 16-bit `registers`
(AX/BX/CX/DX/SP/BP/SI/DI/CS/SS/DS/ES/IP/FLAGS, lower-case keys), a nonempty
`hidden_state` account, and `memory_manifest_sha256`. In a physical record this
digest must identify an actual `initial-memory` artifact. That manifest should
list every initial memory region and its exact hash, including uploaded IVT,
code, stack, reset trampoline, and memory-default policy. Supply the binaries
themselves as additional hashed artifacts. Record both physical reset state
assumptions and the known initialized state at the measurement boundary.

Each stimulus is `{pin, value, reference, offset, unit}`. Pin is RESET/READY/NMI/
INTR, value is integer 0 or 1, reference names an observed edge/accepted write,
offset is finite numeric, and unit states external CLK edges/ns/etc. Quiet
controls must explicitly record low NMI/INTR. Do not invent an instruction-start
timestamp for a physical CPU. Full pin waveforms remain required separately.

`observation` contains a nonempty `summary`, all fourteen `final_registers`,
`state_method` (measured or reconstructed, with basis), `classification`
(including `inconclusive` where appropriate), `alignment`, arrays `frames` and
`marker_writes`. Recommended frame fields are vector, saved CS/IP/FLAGS, physical
stack addresses, ordered bytes, and raw-trace references. Recommended marker
fields are name, physical address, value, accepted-write timestamp and lanes.
Unexpected outcomes remain data; this parser never compares them to a selected
provisional policy. In particular an unexpected partial IRET read/SP sequence
must not be discarded merely because the synthetic interpreter differs.
If an unexpected path prevents a complete final dump, keep all register keys,
use null for unobserved final values and classify the capture `inconclusive`.
Null final values are rejected for other classifications. State the missing
measurements explicitly; do not invent a final FLAGS value.

`fixture` requires name, firmware_revision, host_revision, clock_hz,
clock_method, stop_method, automatic_nmi_dump. Physical clock_hz is finite and
positive; automatic_nmi_dump must be boolean false. Also record capture software,
adapter patch hash, wiring description, voltage translation, READY policy,
sample rate, missing transitions and exact noninterfering stop configuration in
the `fixture-config` raw artifact. A physical record requires `cpu.family` =
`80286`, nonempty vendor/part/markings/stepping and finite positive voltage. Use
the literal `unknown` for an unestablished stepping; never infer it from the
nominal clock or copyright alone. Add temperature and part photos as available.

Physical records require at least `bus`, `pins`, `initial-memory`, `final-memory`,
`cpu-marking`, `fixture-config` artifacts and nonempty control links. A batch must
contain the linked captures, with the same part identity and fixture settings;
synthetic or missing controls fail. Repeats can link each other, but the reviewer
must additionally verify that the protocol's distinct positive/negative controls
were executed. Structural links alone do not establish adequate coverage.

Primary documents require `source` title, publisher, document_number, date,
revision, URL (`url`), page, scope, hypothesis and limitation, with nonempty
strings, plus an `original-document` artifact. Record unknown dates/revisions
explicitly. Observation describes direct wording separately from inference;
page fields should distinguish printed page from one-based PDF page.

The validator checks integrity and completeness, not historical truth or
physical authenticity. Fabricated envelopes in parser unit tests are local
negative/structural test material and are never exported as physical evidence.
`--require-physical` is a provenance filter, not an evidence-gate override.
