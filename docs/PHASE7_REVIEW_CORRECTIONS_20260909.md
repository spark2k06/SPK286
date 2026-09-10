# Independent changed-boundary review — 2026-09-09

Reviewer: separate agent `/root/independent_phase7_review`. This addendum follows
[INDEPENDENT_REVIEW.md](PHASE7_INDEPENDENT_REVIEW_20260909.md) and preserves that report's original
findings, historical failures, scope and evidence limitations. The reviewer again
operated read-only on candidate and production input and wrote only reviewer scratch.

## Exact repaired candidate

- Root: `build/phase7-closure-20260909-candidate`.
- Manifest: `build/phase7-closure-20260909-main/final-source-manifest.json`.
- SHA256: `235b0b15d1eaaacf37eae1bb708d9c44e076e5b4b5f736b9dae5f5f2ba39d185`.
- Independently verified: all 409 files match; inventory is identical to the
  original manifest. Exactly four files changed: `Makefile`,
  `sim/unit/spk286_string_io_lifecycle_tb.sv`, `tests/test_phase7_completion.py`,
  and `tools/audit_io.py`.
- Every RTL and microcode source/generated file is byte-identical to the
  previously reviewed snapshot. Prior functional/physical evidence can be reused
  for these unchanged inputs, explicitly labelled historical. New test/gate/audit
  inputs require fresh executable validation; prior regression is not a new run.
- Fresh independent identity and focused checks:
  [changed-boundary-results.json](../build/phase7-closure-20260909-review/changed-boundary-results.json), reproduced by
  [review_corrections.py](../build/phase7-closure-20260909-review/review_corrections.py).
- Exact 328-file executable-input manifest independently verified:
  `build/phase7-closure-20260909-main/final-executable-inputs.json`, SHA256
  `f5da66b8427b83d44aa2da2b61e70105d072564653b17793dbf2359dcf76adba`.

## Findings disposition

| Finding | Changed-boundary assessment | Verification |
| --- | --- | --- |
| R1, missing arithmetic target | Corrected. `Makefile:228-230` maps the restored phony target to the existing arithmetic script; string/I/O chaining is preserved. | Reviewer freshly ran all four increment/complete dry-run entrypoints successfully. A retained unit test covers target resolution. This does not claim the nested expensive gates were executed. |
| R2, repeated-input temporal coverage | Corrected test and mutation design. The 376 original lifecycle cases remain, followed by 24 new byte/word, even/odd port, DF-direction and READY-delay cases. New input samples advance by accepted physical transfers; both halves of an odd word share their logical sample. Expected memory is derived from the stimulus function, not from CPU output. Complete final architectural state is additionally checked. | Both simulators report 400 cases and 35,477 checks in the coordinator's final lifecycle run. The retained nineteenth I/O mutant matches the reviewer-demonstrated general stale-input fault and requires the specific sample-mismatch assertion. Final mutation audit result is recorded in the validation update below. |
| R3, completion branch coverage | Corrected. A temporary explicitly synthetic valid fixture reaches the review branch; independent negative fixtures check review status, independence, identity, changed manifest, report hash/path and evidence hash with specific reasons. | Reviewer freshly executed all three completion test methods successfully, including the new checks. The synthetic fixture is not actual approval or primary evidence. |

No new actionable defect was found in these changes. The initial lifecycle build's
four Verilator conditional-width warnings correctly failed validation. The repaired
test uses explicit `backward != 0` conditions and does not suppress the warnings or
change expected behavior. Its failed log remains historical failure evidence;
`input-lifecycle-both-2` is a separate successful run.

## REP evidence disposition

**Nonzero REP TF granularity: supported for the bounded development contract, with
explicit inference.** IBM's October 1990 Compatibility printed p.9 explicitly
states the 80286 repeated-MOVS iteration behavior. Generalization to other REP
primitives and first-prefix restart on nonfinal boundaries is supported as an
architectural inference from the common Intel 286 REP/event mechanism and
preservation of remaining CX/SI/DI work. The implementation and tests match that
contract. Keep direct MOVS documentation, inferred generalization, and synthetic
test execution separately identified. This reviewer did not obtain physical TF
captures for every primitive or chip revision, and the disposition does not settle
fault-TF behavior.

**REP initial CX=0 competing-event ordering remains unresolved and blocking.** The
contradictory pending-interrupt/count order in Intel sections identified by the
original report is unchanged. Correct no-element side effects do not adjudicate
saved event CS:IP. No new allowance or automatic source-precedence rule is granted.

## E7 diagnostic and final limits

The coordinator's diagnostic-only harness was inspected. It keeps the pinned
compressed E7 hash, prepares cases through the unchanged strict parser, preserves
all expectation values, records all preparation failures and writes a separately
labelled partial batch. Actual simulator log reports 4,999 executed / 4,999 passed /
0 failed. Required index 1100 remains a preparation failure, so one required case
remains unexecuted in this diagnostic cohort. No admission exclusion was added.

The original combined run still has 5,000 E7 cases unexecuted; the later partial
diagnostic is additional evidence rather than a rewrite of that historical run.
Strict E7 acceptance and complete physical admission remain failed. Publication
remains held. Neither a correct diagnostic cohort nor review concurrence supplies
the missing captured IOW payload.

The corrected code/test boundaries are satisfactory subject to recorded final
executable validation. **No complete Phase 7 development approval, integration
approval, Git-delivery claim or architectural release approval is granted by this
addendum.** REP zero-count evidence, E7 admission, full final validation and actual
delivery remain separate gates. D-026 still contains only `failed-iret-nmi`,
`sti-old-if` and `fault-tf`; those inherited questions alone do not block development.

## Validation update

The completed coordinator I/O audit passed with status 0: 19 intended mutant
rejections and three passing pristine controls. The reviewer independently checked
its log hash, all 19 status-1 detection markers, all three status-0 pristine markers
and the exact stale-input assertion in that mutant's own run log. Complete log
SHA256: `1c821b6abdf5ef7458b38a442141527887d5b94257977402e1211af4391e6c4a`.
The lifecycle, focused-test, strict E7 and diagnostic E7 log hashes were also
independently verified. See [final-audit-verification.json](../build/phase7-closure-20260909-review/final-audit-verification.json).

**R1, R2 and R3 are closed for the exact reviewed correction inputs. Independent
review of the corrected functional/test boundaries is satisfactory.** Ordinary
final regression is still running at this addendum's completion; no final-regression
pass or full Phase 7 gate success is inferred. This reviewer did not start duplicate
simulator or synthesis runs. The REP/E7 and release/delivery limits above remain.
