# Null-segment commit specialization — 2026-10-05

Status: **ARBITRARY_INPUT_EQUIVALENCE_AND_DIRECTED_PASS**.
Full regression is **AUTHORIZED_AFTER_TIMING_CLOSURE_NOT_RUN**; no physical
timing or hardware result is claimed by this CPU-only change.

One combinational assignment specializes the protected DS/ES null-selector
commit. The actual segment-reload qualifier already requires the operation,
permission, PE and valid temporary selector. Under that qualifier, a null
selector uses tmp0, has TI/index zero and cannot produce an address carry.
The inactive-descriptor and non-SS guards remain explicit. General descriptor
services, pre-fault consumers and selector outputs are unchanged. No state,
microcode word, cycle, register or interface is added.

The reusable `scripts/test_null_segment_commit_equivalence.py` reconstructs
the complete reference by reversing only this assignment. Its source-extracted
actual qualifier/selector cone proves all ten observable outputs for arbitrary
binary inputs and retained state, without protocol/reachability assumptions.
Missing SS/active guards, a wrong selector slice and a broken opcode qualifier
are each rejected. The installed raw source SHA-256 is
`325f51e6a91ae9c309786c17da8c22aa3264b3084314008b43b7cc41fd44f6db`.

Strict executor lint passes. The original protected-foundation and segment-
lifecycle benches pass both simulators. The existing directed termination
mode of expand-down passes Icarus and includes DS/ES null acceptance and SS
fault/no-write checks. Its Verilator frontend was stopped after excessive
memory use; that simulator result and the longer matrix are not PASS claims.
No bench expectation or architectural result is changed.

[Sealed CPU-only evidence](evidence/null-segment-specialization-20261005/manifest.json)
binds the applied proof, exact copied CPU/test/compiler inputs, commands,
logs and directed coverage. The PCAT consumer separately regenerates and
proves its own timed executor; board logic is outside this repository.
The generic cone maps from 485 to 446 gates and its permission-to-result
depth falls from 35 to 6. These are generic gates, not FPGA ALMs or timing.

The previously stale standalone selection is refreshed with the dated
`tools/profile_cpu_selected_20261005.json`, retaining both historical
contracts unchanged. [Applied maintenance evidence](evidence/profile-selection-refresh-20261005/manifest.json)
records deterministic generation, installed identity, strict full-CPU lint,
dual schedule/prefix/metadata oracles, reset/fetch checks and seven rejected
identity mutants. CPU, timing policy and test expectations are unchanged.
