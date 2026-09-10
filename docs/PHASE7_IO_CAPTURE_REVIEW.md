# Scalar I/O capture problem — 2026-09-08

Current D-037 policy (2026-09-09): the corrected strings/REP and scalar/string
I/O implementation is integrated in ordinary repository sources. All 307
required files remain in scope. REP initial-zero-count ordering is an open
engineering policy; exactly one incomplete E7 capture is NOT EVALUABLE, with
4,999 evaluable E7 records still required. These and the three inherited D-026
notes are nonblocking for functional/development acceptance. Final executable
validation, independent functional approval and verified delivery remain required.
See [the current policy](PHASE7_FUNCTIONAL_POLICY.md). Historical text below
retains its original dates, counts and conclusions; its incompatible REP/E7
closure prerequisites are superseded by D-037.

Status: reproducible corpus/adapter blocker for full scalar-I/O acceptance.
This is not one of the three provisional Phase 6 evidence exceptions. No record
has been revoked locally, excluded, edited or assigned a fabricated port value.
The IN/OUT prototype remains outside the production branch's source tree.

Current closure status (2026-09-09): independent review has been performed and
the 4,999 complete E7 observations have passed a separate diagnostic RTL run.
The required incomplete observation still blocks strict E7 admission. Historical
prototype descriptions and counts below retain their original run scope.

## Exact input and observations

- Pinned corpus: `37c73caf53dcd22d3dd369ff09305d13d117a4fe`.
- File: `v1_real_mode/E7.MOO.gz`, index 1100.
- Hash: `c56d37647cc2dbcce82ca640fdd25ddea1f3ee5e` (not revoked).
- Instruction: OUT immediate-port,AX; encoded bytes E7 02 F4.
- Initial AX: F6CA; initial/final IP: 3848/384B; no EXCP payload.
- The original upstream `tools/moo2json.py` and project parser agree on the
  complete initial/final states, hash, instruction bytes and all cycle fields.

The capture advertises an IOW Ts at address 2 with BHE# low. The subsequent Tc
has `io_status=0` and `data_bus=0`, then the capture reaches HALT without a recorded
write strobe or write payload. The normal captured pattern is an IOW Ts followed
by a Tc with io_status bit 0 set and data on the selected lane(s). Address and BHE
must be latched at Ts because the physical address lines may already change at Tc.

The strict port-record parser rejects this as `incomplete captured I/O cycle`.
It does not silently construct an expected write from final state or mask away
the missing captured transaction. The public revocation list was checked on
2026-09-08 and still contains only the three already pinned revoked hashes.
Repository issue searches for E7 and I/O did not find an existing disposition.

## Scope of the successful independent work

The isolated prototype implements byte/word IN and OUT with immediate/DX ports,
using the existing operand/BIU handshake. It preserves FLAGS, handles odd word
port carry, and isolates I/O from memory and INTA. The capture responder returns
FF independently of expected results, as documented by the pinned corpus.
Expected port records are comparisons only.

- All 35,000 cases in E4, E5, E6, EC, ED, EE and EF pass with exact captured port
  count, address, lane, direction and selected-data comparison; no selection or
  prefix exclusions. This is seven full families, not the complete I/O set.
- E7's full run fails preparation; its 20-case development sample passed but is
  not counted as full-family validation.
- Both simulators pass 452 directed cases covering variable read streams,
  exact write payloads, ports 0/1/2/FF/100/FFFE/FFFF, both widths, independent
  READY waits, segment prefixes, paused consumers and irreversible reset effects.
- Compiler tests/audit, Verilator lint and Yosys structural/mapped synthesis pass
  for the isolated 190-word image. Six intended port-comparator mutations are
  rejected while the pristine record passes.
- A complete parser scan of all 40,000 scalar-I/O records finds this single
  incomplete capture. The other 39,999 records have complete I/O records; that
  parser count is not an additional RTL execution count.
- The full Phase 7 gate, full I/O family gate and independent architectural
  review remain incomplete. No I/O implementation commit is claimed.

## Smallest remaining evidence/action

Obtain the original capture/export trace for this hash, a corrected upstream
capture or an evidence-backed upstream disposition. Establish whether the IOW
Tc/strobe/data are missing from export or whether the physical transaction
actually differed. A justified corpus-provenance change can then be reviewed
without altering the preserved 474,049-case baseline. Merely skipping index 1100
or changing expected data to make the run pass is not acceptable.

Intel 210498-005 Appendix B OUT (printed B-81) specifies the source and port
extension and no ordinary Real Mode exception for OUT. It does not explain this
capture's missing write strobe. The source of the anomaly is unproven; do not
claim a CPU defect, a chip erratum or a repaired capture from this observation.

The reduced input and original-parser comparison are retained with the I/O
prototype recovery package. Reproduction uses the pinned file and the strict
`captured_io_cycles` helper; it needs no external peripheral or machine model.

## Preserved local recovery

The new ignored package `.cache/phase7-io-recovery-20260908/` contains a complete
223-file candidate, the isolated 18-file I/O delta, strict reproduction guide,
input/evidence hashes and the reduced capture. It is outside `build` so an
ordinary build clean does not remove it. Both original Phase 6 packages remain
untouched.

- `candidate-source.zip` SHA256:
  `bc088f9ad048c96f66c0fcc28cf07d6d453bf1c30b9cf9258cb0d3dc27a65660`.
- `manifest.json` SHA256:
  `463a6c6018ed101f3e56be5d1a0baf9f410a5d8433d1c2d58295eb584ac4adac`.
- `SHA256SUMS` SHA256:
  `3bdb5f65489845e771bd78c9c7e7d28f7832a527b7ed8509ab5a620d3a6077ba`.

The archive's inventory and every input hash were checked before safe extraction
to an absent ignored directory. The recovered compiler verifies the exact
41-entry/190-word generated image. `git apply --check` accepts the delta against
a separately reconstructed pre-I/O input subset. No patch was applied to the
production checkout. Full-regression decoder/scope expectations and the old
word-limit mutation anchor are explicitly unfinished in this prototype, in
addition to E7 acceptance; the package is not a verified implementation commit.

## Closure-session evidence and diagnostics - 2026-09-09

Read-only upstream inspection again found HEAD
`37c73caf53dcd22d3dd369ff09305d13d117a4fe`, the same two E7 source revisions,
and the same three original revocations. All three current public issues were
inspected; none supplies an E7 disposition. This session created no issue and
contacted no maintainer. Publication remains **PENDING_BY_USER_REQUEST**.

The original strict reproduction again exited 1 with `incomplete captured I/O
cycle`, using the unchanged compressed-file hash and original index/hash. This
reproduction executes zero RTL cases. Its reduced capture, result and command
are retained under `build/phase7-closure-20260909-main/e7-strict`.

A separate diagnostic harness attempted preparation of every original E7 record
with the existing strict parser. It executed only the complete observations and
recorded the incomplete observation as still required; it made no change to
the admission runner, parser, corpus, masks, revocations or expected values.

| Diagnostic-only E7 accounting | Cases |
| --- | ---: |
| Required original records | 5,000 |
| Prepared / executed / passed | 4,999 / 4,999 / 4,999 |
| RTL execution failures | 0 |
| Required but unexecuted | 1 |
| New admission exclusions | 0 |

The batch ran on a fresh Verilator binary built from RTL and microcode byte
identical to the independently reviewed candidate. Exact parser, source, binary,
batch and identity hashes are in `e7-partial/diagnostic-result.json` and the
closure validation/recovery record. Expected port data remained comparison data.
This cohort does not qualify E7 as passed or replace the historical full run in
which all 5,000 E7 cases were unexecuted due to file preparation failure.

Independent review additionally exposed repeated-INS constant-data test coverage:
a stale-first-input mutant survived the old directed banks. The continuation
candidate adds 24 accepted-access-dependent samples and retains that mutant;
unchanged RTL passes while the intended fault is detected. This verification
repair concerns INS data ownership and does not explain or repair E7 acquisition.

The same smallest evidence action remains: obtain original acquisition/export
data, a corrected capture, or an independently supported upstream disposition
with precise provenance and admission impact. Inferring the missing write from
AX, voting to skip it, or proposing a waiver does not satisfy this requirement.
