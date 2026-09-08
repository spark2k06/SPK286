# Phase 6 independent architectural review

Status: approval withheld; unresolved 286 evidence blocks release and Phase 7.
The review was performed in a separate read-only reviewer context. It did not
edit RTL, generate the oracle, or perform the implementation's validation run.

## Unresolved evidence

### Failed IRET and NMI inhibition

The candidate releases NMI inhibition at CF opcode acceptance, even if a later
stack word faults. Intel 210760-002 (1987), chapter 3, establishes one pending
NMI, blocking during service, and release after IRET execution or reset. It does
not explicitly distinguish successful return from a faulting attempt. Neither
210498-003 (1985), 210498-005 (1987), the operating-system writer's guide, the
B-2/B-3 information sheet nor the examined 86BUGS physical-report collection
supplied a discriminating 286 result. Modern IRET/NMI text is not used to fill
that gap. No physical 286 interface is available in this workspace.

The lifecycle test characterizes the candidate; it does not validate this rule
against hardware. The independent interruptibility model raises
`UnresolvedEvidence` for a blocked NMI followed by failed IRET instead of
manufacturing a hardware oracle.

Required capture: accept NMI with a valid frame; queue another rising edge while
blocked; arrange SP=FFFF immediately before IRET; install valid #GP and NMI
vectors and usable descending exception stack space. Observe whether #GP is
followed by the second NMI before the first #GP handler instruction. Record
CPU vendor/marking/stepping, complete initial/final state, NMI waveform, memory
traffic and code-fetch order. Repeat with the second or third IRET word failing
(starting SP=FFFD and FFFB) and with an ordinary successful IRET control.
Use a CPU fixture, not SPK286 or another emulator, for adjudication.

### STI when IF was already one

The original 1985 STI page B-102 expressly describes a delay through the next
instruction. It does not expressly qualify that delay by old IF. The candidate
has the old-IF=0 qualifier; this is an unvalidated interpretation. Directed
IF=1/STI and consecutive-STI cases characterize it with INTR raised only after
STI has begun, avoiding acceptance before the tested opcode.

Required capture: compare IF=0/STI/MOV, IF=1/STI/MOV and IF=0/STI/STI/MOV, with
an INTR edge during the first STI. Record whether INTA precedes the following
MOV, and retain complete return-IP frames. The ordinary IF=0 case is the control.

### TF and instruction exceptions

The follow-up independent review judged suppression of a new TF trap for a
faulting instruction the most defensible provisional Real Mode policy, not a
demonstrated RTL defect. Sections 5.2.2/5.2.3 describe saving FLAGS and clearing
live IF/TF; section 9.7.1 ties stepping to instruction execution/completion.
The priority table alone does not prove a fault creates a pending single step.
Appendix D (1985)/C (1987), item 12, nevertheless says instruction-exception
handlers remain single-steppable. Its same sentence includes INT, contradicted
by Intel's INT-specific correction. That correction does not expressly settle
the exception half of the sentence. These sources contain unreconciled text.

Required capture: TF=1; MOV word [FFFF],AX; valid #GP/#1 handlers, first without
NMI, then with NMI pending during the MOV. Distinguish #GP/#1/NMI entry order
before any handler instruction and inspect each saved CS:IP/FLAGS frame.
The candidate produces #GP followed by eligible NMI, without manufacturing a
retirement or a #1 for the faulting MOV. Corpus TF is not exercised.

## Defect reproduced and corrected

An already owed trap from a **successfully completed** instruction is a separate
case. CLI at CS:FFFF with TF=1 delivered #1 uninterrupted but #GP if execution
paused just after retirement. The next-opcode demand fault incorrectly preceded
the retained trap. The reduction failed before the fix (vector 13 instead of 1).
Arbitration now handles an active instruction's fault first, then owed boundary
events, then an unavailable next opcode. Both pause variants pass and save
IP=0000. No exception-TF assumption is needed for this correction.

## Coverage findings and follow-up

The first review found no definite saved-IP, false-retirement, write-replay,
CS/cache-coherence or INTA ownership defect in the admitted hardware path.
It confirmed shared microcode and the original architectural/stack/operand/BIU
owners; EXCP metadata does not instruct the DUT to take an exception.

It requested an independent event-qualification/interruptibility model,
frame/IVT alias cases, handler modifications of saved IP/FLAGS, dependent seeded
streams and equivalent lifecycle perturbations for IRET. The candidate now
includes `Interruptibility`, `event_streams.py`, alias vectors and IRET-stage
pause/cancel/reset tests. Their executed results and the refreshed review must
be read in `PHASE6_HANDOFF.md`; this paragraph does not itself assert a pass.

The refreshed independent review inspected the fix and all of these additions.
It closed the concrete arbitration defect and the model/interaction coverage
findings, found no additional concrete RTL defect within its bounded scope, and
confirmed that the model does not import DUT/compiler/adapter expected-state
helpers. It observed the development logs: 1,932 instruction cases, 204 lifecycle
scenarios and 96 streams/4,670 completions pass in each simulator. It did not rerun
the release gate. Architectural approval remains withheld on the three evidence
questions above; the refresh is not Phase 6 readiness or Phase 7 authorization.

## Primary sources

- [Intel 210498-003, 1985](https://bitsavers.trailing-edge.com/components/intel/80286/210498-003_iAPX_286_Programmers_Reference_1985.pdf), STI B-102, IRET B-48–50, chapters 5/9 and Appendix D.
- [Intel 210498-005, 1987](https://bitsavers.trailing-edge.com/components/intel/80286/210498-005_80286_and_80287_Programmers_Reference_Manual_1987.pdf), chapters 5/9 and Appendix C.
- [Intel 210760-002, 1987](https://bitsavers.trailing-edge.com/components/intel/80286/210760-002_80286_Hardware_Reference_Manual_1987.pdf), chapter 3.
- [Intel B-2/B-3 Information Sheet, 21 November 1984](https://www.pcjs.org/documents/manuals/intel/80286/b2_b3_info/), instruction/documentation corrections and bus LOCK clarification.
- [Pinned physical-corpus methodology](https://github.com/SingleStepTests/80286/blob/37c73caf53dcd22d3dd369ff09305d13d117a4fe/README.md), explicit TF/interrupt, wait-state and prefetch limitations.

`docs/phase6_evidence.json` records these open decisions. The release gate runs
the executable checks and then fails closed on unresolved required evidence.
There is no switch that relabels this candidate as a completed Phase 6.

## Development disposition — 2026-09-08

D-026 permits incremental Phase 7 development on a freshly executable-validated
provisional Phase 6 baseline. This supersedes the earlier prohibition on Phase 7
development, not this report's historical findings or withheld architectural
approval. `failed-iret-nmi`, `sti-old-if` and `fault-tf` remain unresolved under
their unchanged candidate policies. See PHASE7_SCOPE.md and the current
development handoff for later validation and Git identities.
