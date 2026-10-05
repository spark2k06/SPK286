# READY fetch chaining: standalone CPU milestone

Status: **STANDALONE_COMPOSED_GATES_PASS**. Fresh standalone checks, the bound vendor v3 general gate and
independent source/coverage reviews have passed. This document does not claim
a literal standalone `make regression` run.

The CPU caller and fetch now reserve space conservatively and can prepare the
next CODE request on READY while preserving response backpressure and restart
handling. The profiled CPU is regenerated from a separately pinned selected
contract; historical baseline files remain unchanged. Missing wildcard bench
debug declarations, architectural #UD sentinel probes, adjust starvation
stimulus and named LOADALL compiler validation are included. No board/native
pins, modern microcode fixtures or Makefile are replaced.

## Fresh validation

* 33 fresh stages passed: strict lint, 355 Python tests, microcode check/audit,
  nine affected or distinct banks in both simulators, supported core MAX probes,
  four standalone-only Yosys sanity checks, normal reset smoke and four native
  state initialization cases.
* The profile checker passes deterministic generation/installed identity,
  45 schedule checks and eight prefix cases per simulator, 43,878 independent
  metadata cases per simulator and both reset/fetch modes in Icarus.
* All 48 MOV vectors actually resume to #UD acceptance with their original
  signatures, retained CS:IP/FLAGS and one retirement. No stack entry or false
  unsupported latch is used to terminate these probes.

## Coverage composition

All 40 functional RTL inputs, 20 literal microcode sources, three generated
ROM/package files and two selected generated profile files match the bound
vendor sources byte for byte. The selected profiled CPU SHA-256 is
`847a6930469e67d7345847e39f57ab51a5fe3556c73f8741d5e9c7d69c6038c7`.

Standalone registers 129 unit banks: 125 TB sources are byte-identical to vendor,
and four differ and were executed fresh. The nine fresh banks repeat five of
the identical sources, leaving 120 common-only banks for shared evidence. All
24 runner vector generators match. The header contains the same 136 typed
declarations despite grouping/formatting differences, explicitly recorded as a
static declaration bridge, not byte identity. Modern standalone fixtures are
kept and covered by its fresh Python suite.

Composed coverage is 129 Icarus/128 Verilator unit banks
with the existing Icarus-only full expand-down matrix preserved. Vendor's extra
event-arbitration bank is not labeled a standalone execution. The five distinct
legacy auditors of other release targets are outside this composition.

## Self-contained evidence

[Packet manifest](evidence/ready-chaining-20261004/manifest.json) lists stored
relative paths and SHA-256 values. The packet includes raw fresh receipts/logs,
scope inventory, profile/state data and all 1,079 frozen standalone inputs.
Shared evidence includes its actual receipt, full log, source inventory, cache
control records and independent review receipts/helpers. Historical `source_path` or build paths inside receipts
describe provenance; none is required to read the packet's conclusions. The
external hardware-reference corpus is identified by hash in shared evidence;
raw corpus acquisition is necessary only to replay that shared corpus scope.

Run `python3 docs/evidence/ready-chaining-20261004/verify_packet.py` to verify
stored hashes/source bundles; the checker reads only this packet. The packet
does not certify MiSTer, a motherboard, native 286 pin timing or cycle accuracy.
Provisional instruction profiles remain provisional.
