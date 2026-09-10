# REP event evidence update - 2026-09-09

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

Current status: independent review performed; nonzero REP TF supported with
explicit inference beyond MOVS. Initial CX=0 competing-event evidence remains
unresolved and blocking. Candidate RTL is unchanged. The research paragraphs
before the dated independent disposition below preserve their pre-review status.

## Single stepping

IBM, Hardware Interface Technical Reference, Compatibility, October 1990,
printed page 9 (PDF page 13), explicitly identifies the 80286 when describing
single stepping of repeated MOVS. The relevant sentence is:

> The 8088, 8086, and 80286 microprocessors take a single-step interrupt after every iteration step.

Source: http://www.mcamafia.de/pdf/ibm_hitrc13.pdf

The complete page and its preceding page were rendered and visually inspected.
The section discusses a 386 anomaly, but its explicit 286 comparison is direct
286 documentation; this is not an inference from the 386's desired behavior.
The PDF identifies IBM/PHW as author and the pages identify October 1990.
Its PDF SHA256 is cceffa6a769877fe20041700b7fe86933789d69d248cae6724dc6955e1211303.
The HTTPS host certificate does not match; the successful read used its public
HTTP mirror. The retained hash identifies those exact bytes, not authenticity
of every mirror. No TLS verification was disabled.

This supports the candidate's trap after each completed MOVS element. The
existing directed boundary/lifecycle tests exercise that policy. Applying it to
all other REP primitives uses their common repeat/interrupt mechanism in Intel
210498-005, sections 3.7.2 and 5.2, rather than an explicit IBM assertion about
those other opcodes. That inference and the saved restart frame still need the
focused independent review. It does not adjudicate TF on a faulting element,
which retains the original Phase 6 fault-tf disposition.

## Initial CX=0 with a competing event

Intel 210498-005 section 3.7.2 and Appendix B, printed B-93, present different
orders for the count and pending-interrupt checks. The current implementation
performs no element access for an initial zero count, then accepts an eligible
event at ordinary completion with next IP. A pin transition before instruction
acceptance may instead be accepted at the preceding boundary; it is not an
observation of the zero-count REP policy.

IBM's sentence above does not resolve that competing-event case. No physical
286 execution with controlled event phase has been obtained. The question
remains pending and is not added to D-026. A useful physical experiment needs
CX=0/1/3 controls, complete event frames and a phase sweep tied to accepted marker
writes; code prefetch alone cannot locate instruction execution.

## Independent disposition and capture preparation - 2026-09-09

The separate reviewer `/root/independent_phase7_review` has now inspected the
original 409-file candidate and its primary evidence. See
[the independent report](PHASE7_INDEPENDENT_REVIEW_20260909.md). The coordinator
also rendered and read IBM PDF pages 12-13 and Intel's relevant original pages.
The original candidate and all retained PDF hashes remain unchanged.

Nonzero repeated MOVS single stepping is directly supported by IBM printed p.9.
Using the same per-element trap boundary for the remaining REP primitives is
accepted for the bounded development contract as an explicit inference from
Intel's shared repeat mechanism, not as a physical capture of those primitives.
Prefix-preserving nonfinal restart and completed-instruction next IP were reviewed
against that mechanism and the event frame contract. The independent review
does not claim that section 5.2 alone gives a REP-specific execution trace.
Faulting-element TF retains the inherited `fault-tf` policy.

The initial-zero-count question remains **unresolved and blocking**. Both editions
retain opposing check orders:

| Primary source | Interrupt-first description | Count-first description |
| --- | --- | --- |
| Intel 210498-005, 1987 | Section 3.7.2, printed 3-22, PDF 78 | Appendix B, printed B-93, PDF 301 |
| Intel 210498-003, 1985 | Section 3.7.2, printed 3-24, PDF 74 | Appendix B, printed B-90, PDF 290 |

The earlier edition is corroboration of the inconsistency, not a correction.
A focused search and the [B-2/B-3 errata material](https://www.pcjs.org/documents/manuals/intel/80286/b2_b3_info/)
did not provide a discriminating REP CX=0 correction. No precedence between
prose and appendix is inferred. Original PDFs and rendered-page identities are
retained in the closure recovery package. The no-element-access invariant is
separate: the reviewed empty-count branch precedes all string memory/port
operations and the existing directed tests check that invariant.

### Discriminating physical capture procedure (designed, not executed)

1. Record actual part markings/stepping qualification, board, clock, voltage,
   capture firmware and source/binary hashes. Use writable RAM, a known valid
   stack and separate log/source/destination regions. Fix byte/word width,
   DF direction, segment bases and exact prefix order for each run. Start with
   REP MOVSB, then MOVSW and independent INS/OUTS/compare controls as required.
2. Install separate vector 1, NMI and chosen INTR handlers. At entry, copy the
   untouched saved IP/CS/FLAGS, live CX/SI/DI/AX and SP to a per-entry log before
   destructive register use. Preserve and log every accepted input/output and
   destination write. Keep handler writes outside the tested region. Return
   with IRET, then record final registers, memory and completion marker. Log any
   intentional saved-TF edit before IRET; do not present edited frames as raw.
3. Place an accepted memory marker write immediately before the exact target
   bytes, with a distinct marker after them. Capture address, selected lanes,
   direction, data, status and READY for both markers. Sweep external-event
   phase in clock-edge increments around the first marker's accepted write,
   continuing through the final marker. Record actual pin-transition time,
   synchronizer assumptions/latency and sampling uncertainty separately from
   any inferred latching, eligibility or acceptance boundary. Prefetch is not
   an execution timestamp. Retain complete traces, including waits and INTA.
4. Use CX=0/1/3 for every primary trial. Run NMI with TF=0 and no previously
   blocked/pending NMI; run INTR with IF=1, TF=0 and no STI/SS inhibition. Hold
   INTR until acknowledgement, with an independently supplied second-INTA
   vector. Run TF=1 with external events absent as a separate granularity/frame
   control. A TF-only observation cannot by itself decide INTR/NMI ordering.
   Add masked-INTR, no-edge/held-high NMI and TF=0 controls. Test SS-load and STI
   adjacency separately: their eligibility changes must not masquerade as the
   primary zero-count discriminator.
5. For CX=1/3, identify which element effects precede each event and verify the
   remaining count, next indexes, complete frame and IRET resumption. Changing
   input samples and explicit output counters must expose duplicate or stale
   effects. For CX=0, require zero string-element memory/port activity and
   unchanged indexes/count; compare saved first-prefix IP versus next IP.
6. Classify an event taken at the preceding instruction boundary separately:
   it saves the target prefix IP but does **not** distinguish the two zero-count
   policies. Marker-relative sweeps and nonzero controls help bound the window;
   they do not expose internal opcode acceptance. A discriminating claim needs
   an independently justified event window after target acceptance and before
   its zero-count completion. If the available capture cannot establish that
   window, label the result inconclusive rather than choosing a policy from
   frame IP alone. Reject runs with ambiguous eligibility or incomplete frames.
7. Retain every trial, phase, control, raw trace and disposition, including
   inconclusive runs. Review the capture procedure and actual results separately.
   No hardware access or raw capture was available in this closure session.

The smallest next input is a timing-valid physical discriminator or an explicit
applicable Intel clarification. No new D-026 allowance is created.
