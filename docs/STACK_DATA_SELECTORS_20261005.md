# Consumed stack DATA selector specialization — 2026-10-05

Status: **ARBITRARY_INPUT_CONSUMER_EQUIVALENCE_AND_DIRECTED_PASS**.
Full regression is **AUTHORIZED_AFTER_POSITIVE_FOUR_CORNER_SETUP_HOLD_NOT_RUN**.
No fitted timing or hardware result is claimed by this CPU-only change.

Four combinational DATA selectors retain the micro-operation, phase and all
call/return/frame-state guards. Permission stays on the original real
operations and stack request; the payload mux can prepare the same address
before the late permission arrives. No architectural state, clock, cycle,
microcode word or memory operation is added.

The raw source SHA-256 is
`8d41e0187bef3081728780e4683c9e312b1f4beb1f3c40a6244d465c32799710`.
The whole reference is recovered by undoing only the DATA block and offset
selector names. The other permission/request assignments are byte-identical.

The source-extracted coupled proof compares all actual top address, four-cache
protection/fault consumers and the complete original operand outputs/two
next-state bits for arbitrary binary state and inputs, without assumptions.
Both actual raw and downstream timing variants pass. Four real mutations per
variant are rejected. No overlap state, descriptor/task/vector/I/O override,
READY dependency or reset/cancel priority is assumed away.

Idle stack_offset and its unused auxiliary call-stack address intentionally
can differ. The original flat checker and independent October2 reference are
retained unchanged; the historical producer replay still passes, and a real
current flat-idle counterexample is explicitly preserved. The consumed
interface contract is a separately named proof, not a weakened flat verdict.

Strict complete raw and downstream timed CPU lint pass with empty logs. Five
unchanged RAW CPU banks pass Icarus and Verilator with identical results:
call-stack precheck9; call-gate accessed420checks/144cases; protected outer
event6checks/499READY stalls; protected-return restart81checks/27cases; stack
frame lifecycle39296checks/339cases. Timed behavior is proved by the coupled
SAT proof; these ten simulator runs do not simulate the timed variant.

[Sealed CPU-only evidence](evidence/stack-data-selectors-20261005/manifest.json)
binds complete copied CPU/test/compiler inputs, commands, logs, both proof
variants, historical flat evidence and the exact candidate identities. No
board RTL, BIOS, external corpus, fitter output or compiler objects is included.
The downstream consumer owns regeneration of its actual timing variant and
current reusable contract checker.

Generic ABC mapping of the complete cone changes3577→3580gates. The path from
service_start to stack DATA disappears (previously13generic levels); to access
fault it falls33→29levels. These are generic estimates, not FPGA ALMs/slack.
The selected CPU-only manifest/generator is explicitly refreshed. Historical
baseline/READY manifests, generation algorithm, timing policy and the expected
generated top/events bytes remain unchanged.
