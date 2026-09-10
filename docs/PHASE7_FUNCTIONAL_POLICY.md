# Phase 7 functional acceptance policy — D-037, 2026-09-09

The user explicitly authorizes functional/development closure of Phase 7 with
the five named evidence notes below. This supersedes earlier REP/E7 physical
closure prerequisites, including historical scope, handoff and reviewer gates.
It does not rewrite D-026 or the dated reviews, change expected CPU results,
authorize omissions, or certify historical 80286 timing/complete fidelity.

The required implementation covers milestones 1–9 and all 307 required files.
Phase 8 may begin only after complete executable validation, independent
functional approval, unchanged source/policy identities and verified delivery.
No Phase 8 implementation or downstream machine integration belongs to this work.

## Exact open notes

`failed-iret-nmi`, `sti-old-if` and `fault-tf` keep their original D-026 policies
and unresolved evidence status. `phase6-check` remains strict;
`phase6-exec-check` retains its existing executable/development distinction.

`rep-zero-count-event-order`: initial CX=0 executes zero elements, with no
element memory/port accesses or element-induced SI/DI/CX/FLAGS changes. It
completes at architectural next IP. Eligible events at that completion use
existing priority, pending, mask, TF and inhibition rules. Normal pre-instruction
event recognition and nonzero restart are unchanged. A preceding-boundary event
can save start IP; it does not discriminate zero-count completion. This is an
engineering policy awaiting physical confirmation. The separate nonzero REP TF
documentary disposition and explicit inference beyond MOVS remain preserved.

`e7-incomplete-physical-capture`: only SingleStepTests/80286 revision
37c73caf53dcd22d3dd369ff09305d13d117a4fe, v1_real_mode/E7.MOO.gz, index 1100,
record c56d37647cc2dbcce82ca640fdd25ddea1f3ee5e, compressed SHA256
e163ff1271d61ed9e4cbf6a0150ca3e7b1c756ce7cbcd189e4312eb77b70b729, may be
NOT EVALUABLE — incomplete physical capture. The original strict parser must
still diagnose `incomplete captured I/O cycle`, and independent raw decoding
must confirm the absent write strobe/payload. No expectation is reconstructed
from AX; the raw record is retained and is neither revoked nor a physical PASS.
The whole E7 file remains required: 4,999 evaluable records plus this one note.
Any different identity, digest, reason, second incomplete capture, missing
evaluable record or RTL/comparator mismatch fails admission/validation.

## Separate acceptance dimensions

`make phase7-check` is the authoritative functional/development gate. Its full
execution stage runs the inherited gate, complete corpus, directed/lifecycle
checks, compiler consistency, lint, both simulators, mutation/comparator audits
and synthesis/regression. It then requires a separate independent functional
review bound to immutable executable and acceptance-policy manifests.
`phase7-exec-check` performs the same executable stage without granting closure;
the resulting verified receipt may be supplied to `phase7-check` for finalization
without rerunning unchanged inputs. Receipt and all retained result/log hashes
are checked, along with current manifests and the independent review binding.
Changed inputs or evidence require appropriate revalidation and renewed review.

The policy manifest covers this document, the complete form inventory, the
versioned evidence register, inherited dispositions and every referenced policy
artifact. Review metadata and delivery receipts live outside those inputs to
avoid circular hashing. Unknown notes, stale artifacts, duplicate/missing
records, self-review, wrong reviewer scope/status and unresolved executable
defects fail the gate. Synthetic validator fixtures are never actual approval.

Required population is 1,386,997 non-revoked hardware-derived records:
1,386,996 evaluable executions plus exactly one NOT EVALUABLE capture. Synthetic
directed tests, emulator experiments, lifecycle scenarios and mutation detections
are reported separately. Replay of hardware-derived tests is not a new capture.

`phase7-evidence-check` independently reports physical completeness and remains
unsatisfied while these five notes are open. It is not a functional gate or a
required CI failure. E7 issue publication is held by user request; no messages
to third parties are authorized. Future closure needs the physical/primary
evidence specified in the register. Emulator comparisons retain their provenance
and cannot manufacture missing physical observations.
