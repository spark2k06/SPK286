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
historical instruction-interval schedule. For a CPU in its own device,
`rtl/native/spk286_native.sv` presents the core at 80286 pins; see the
[native bus contract](docs/NATIVE_BUS.md).

## FPGA resources (estimate)

Yosys 0.33 `synth_intel_alm` estimate for Cyclone V, the reference FPGA target. The
counts are Yosys cells, not Quartus ALMs: Quartus packs LUTs into ALMs and
optimizes differently, so its figures differ. Regenerate them with
`make resource-report`.

Integrated core (only the functional bus and interrupt ports connected,
setup ports tied off, debug outputs left open, flattened):

| Top | LUTs | Arithmetic | Registers | M10K | MLAB | DSP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `spk286` | 9,247 | 2,651 | 4,793 | 1 | 0 | 0 |

Per module (hierarchy and all debug ports kept, so it is an upper bound; for
example `spk286_timing_trace` only holds debug counters):

| Module | LUTs | Arithmetic | Registers | M10K | MLAB | DSP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `spk286_micro_executor` | 3,185 | 884 | 902 | 0 | 0 | 0 |
| `spk286` | 1,471 | 496 | 16 | 0 | 0 | 0 |
| `spk286_protected_state` | 1,273 | 88 | 540 | 0 | 0 | 0 |
| `spk286_task_segment_service` | 669 | 65 | 734 | 0 | 0 | 0 |
| `spk286_task_switch_service` | 516 | 296 | 652 | 0 | 0 | 0 |
| `spk286_segments` | 472 | 32 | 256 | 0 | 0 | 0 |
| `spk286_muldiv` | 456 | 299 | 202 | 0 | 0 | 0 |
| `spk286_registers` | 426 | 16 | 160 | 0 | 0 | 0 |
| `spk286_tss_service` | 318 | 142 | 402 | 0 | 0 | 0 |
| `spk286_events` | 266 | 0 | 129 | 0 | 0 | 0 |
| `spk286_decoder` | 229 | 3 | 0 | 0 | 0 | 0 |
| `spk286_descriptor` (x8) | 200 | 0 | 0 | 0 | 0 | 0 |
| `spk286_adjust` | 147 | 100 | 84 | 0 | 0 | 0 |
| `spk286_biu` | 141 | 24 | 90 | 0 | 0 | 0 |
| `spk286_fetch` | 139 | 91 | 98 | 0 | 0 | 0 |
| `spk286_loadall_service` | 123 | 6 | 651 | 0 | 0 | 0 |
| `spk286_prefetch_queue` | 111 | 16 | 58 | 0 | 0 | 0 |
| `spk286_alu` | 108 | 18 | 0 | 0 | 0 | 0 |
| `spk286_operand` | 104 | 0 | 2 | 0 | 0 | 0 |
| `spk286_effective_address` | 100 | 80 | 0 | 0 | 0 | 0 |
| `spk286_control_decode` | 88 | 0 | 0 | 0 | 0 | 0 |
| `spk286_timing_trace` | 77 | 832 | 837 | 0 | 0 | 0 |
| `spk286_microsequencer` | 75 | 45 | 23 | 0 | 0 | 0 |
| `spk286_shift` | 75 | 6 | 57 | 0 | 0 | 0 |
| `spk286_alu_decode` | 42 | 0 | 0 | 0 | 0 | 0 |
| `spk286_operand_decode` | 32 | 0 | 49 | 0 | 0 | 0 |
| `spk286_stack` | 32 | 33 | 0 | 0 | 0 | 0 |
| `spk286_instruction_context` | 19 | 4 | 12 | 0 | 0 | 0 |
| `spk286_flags_decode` | 15 | 0 | 0 | 0 | 0 | 0 |
| `spk286_selector` (x2) | 12 | 86 | 0 | 0 | 0 | 0 |
| `spk286_condition` | 4 | 0 | 0 | 0 | 0 | 0 |
| `spk286_modrm` | 3 | 0 | 0 | 0 | 0 | 0 |
| `spk286_stack_range` | 2 | 34 | 0 | 0 | 0 | 0 |
| `spk286_timing_policy` | 1 | 0 | 4 | 0 | 0 | 0 |
| `spk286_microcode_sync_rom` | 0 | 0 | 0 | 1 | 0 | 0 |
| **Total `spk286`** | **10,931** | **3,696** | **5,958** | **1** | **0** | **0** |

The `spk286` row is the top-level glue logic. The single M10K block holds the
microcode ROM. The generated ROM carries no vendor attribute, so Yosys also
maps it to one block RAM on ECP5 (DP16KD), Gowin (SPX9) and Xilinx 7-series
(RAMB18E1). Multiply and divide are
iterative and use no DSP blocks. The profiled variant in `rtl/timed` is not
covered because Yosys 0.33 cannot parse the module-scope package import in
`rtl/timing`.

## Repository layout

| Path | Content |
| --- | --- |
| `rtl/` | CPU RTL (`rtl/timing` and `rtl/timed` hold the profiled variant, `rtl/native` the 80286 pin adapter) |
| `microcode/source/` | Authoritative microcode source |
| `microcode/generated/` | Committed compiler output; never edited by hand |
| `sim/` | Directed testbenches and simulator harnesses |
| `tools/` | Microcode compiler, SingleStep tools, reference models and audits |
| `scripts/` | Build, lint, test and synthesis scripts |
| `tests/` | Python tests and fixtures |
| `docs/SPK286.md` | Technical reference |
| `docs/NATIVE_BUS.md` | Contract of the 80286 pin-level bus adapter |
| `docs/report/CORE_REPORT.html` | Self-contained technical datasheet (open in a browser) |

## Authorship

SPK286 is directed by Aitor Gómez García (spark2k06). Its RTL, microcode,
tools and tests were written with AI coding agents. The author set the
architecture and scope, defined the verification strategy, ran the testing
and drove the adjustments needed to make the core work. Correctness rests on
that verification — hardware-captured 80286 test data, independent reference
models and mutation audits — not on who or what wrote the code.

## License

SPK286 is released under the [MIT License](LICENSE). Source files carry an
`SPDX-License-Identifier: MIT` line, and the generators emit it in the files
they produce. The license allows the core to be integrated into designs under
any license, including GPL machine cores.

The SingleStepTests/80286 corpus (MIT) is fetched at build time and is not
redistributed; see [the references](docs/SPK286.md#12-references-and-third-party-material).
