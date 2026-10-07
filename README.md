# SPK286

SPK286 is a synthesizable SystemVerilog implementation of an Intel
80286-compatible CPU core, built around project-owned microcode and verified
against hardware-captured 80286 test data.

The repository contains only the CPU: execution core, microcode and its
compiler, prefetch, segmentation and protection, interrupts and exceptions,
task switching, the Bus Interface Unit and the timing policy. Machine logic
(PC/AT chipset, video, storage, BIOS, FPGA board tops) belongs to the projects
that use the core.

## Status

- Real mode: every documented 80286 instruction, checked against the
  SingleStepTests/80286 hardware captures for all 307 real-mode opcode forms.
- Protected mode: descriptors, privilege checks, call/interrupt/trap/task
  gates, task switching, IOPL, exception replacement, double fault and
  shutdown.
- Undocumented instructions: LOADALL (`0F 05`) and SALC (`D6`).
- No coprocessor interface: ESC and WAIT follow the MSW no-NPX rules.
- Timing: functional, dependency-driven execution plus a provisional
  instruction-interval variant. Historical cycle accuracy is not claimed.

Known open items are listed in the
[technical reference](docs/SPK286.md#10-known-limitations-and-open-items).

## Quick start

Requirements: Verilator 5.020 or later, Icarus Verilog 12, Yosys, GNU make and
Python 3 (standard library only). On Ubuntu or WSL, `make bootstrap` installs
them and `make env` checks them.

```sh
make regression        # microcode, lint, directed benches, Python tests, synthesis
make singlestep-fetch  # fetch the pinned SingleStepTests/80286 corpus into .cache
make singlestep        # run every supported SingleStep opcode file
make mutation-audit    # check that the testbenches reject injected RTL faults
make full-check        # everything above plus the profiled variant checks
make help              # all targets
```

## Using the core

Instantiate `spk286` from `rtl/spk286.sv` with the sources listed in
`scripts/rtl_sources.sh` (generated microcode package and ROMs first, then
`rtl/*.sv`). The core exposes a normalized 80286 bus with READY, HOLD/HLDA,
LOCK, INTR/NMI and INTA cycles; see the
[interface description](docs/SPK286.md#3-external-interface-and-biu).
`rtl/timed/spk286_profiled.sv` is a drop-in variant that adds an optional
historical instruction-interval schedule.

## Repository layout

| Path | Content |
| --- | --- |
| `rtl/` | CPU RTL (`rtl/timing` and `rtl/timed` hold the profiled variant) |
| `microcode/source/` | Authoritative microcode source |
| `microcode/generated/` | Committed compiler output; never edited by hand |
| `sim/` | Directed testbenches and simulator harnesses |
| `tools/` | Microcode compiler, SingleStep tools, reference models and audits |
| `scripts/` | Build, lint, test and synthesis scripts |
| `tests/` | Python tests and fixtures |
| `docs/SPK286.md` | Technical reference |
