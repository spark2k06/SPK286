# SPK286 bring-up demo for the ZXTRES+

A CPU smoke test on the ZXTRES+ (Xilinx Artix-7 XC7A100T,
`xc7a100tfgg484-2`): the SPK286 core (`rtl/spk286.sv`) on block RAM runs a
self-checking x86 program and shows the results on VGA. It is not a PC/AT
machine: there is no chipset, interrupt controller, disk, keyboard or
external memory.

The same demo, built from PCAT-286_MiSTer with the core behind that
machine's CPU wrapper, has run on a ZXTRES+: all 22 checks passed at 40 MHz
and the sieve took 1,083,160 cycles per pass. This build, from the SPK286
tree, gives the same screen and cycle counts in simulation.

| File | Content |
| --- | --- |
| `zxtres_demo_top.sv` | Board top: MMCM (CPU clock and 25 MHz dot clock), resets, LEDs |
| `zxtres_demo_system.sv` | The core, block RAM, ROM, text screen and I/O ports |
| `zxtres_text_vga.sv` | 80x25 text on 640x480 VGA, plus a hardware status line |
| `zxtres_cdc_snapshot.sv` | Handshake transfer between the CPU and dot clocks |
| `demo.asm` | The test program (NASM), a 64 KiB ROM |
| `font8x8.hex` | 8x8 font for characters 20h-9Fh |
| `zxtres_demo.xdc` | Pins and bitstream options |
| `build.sh`, `build.tcl` | Vivado non-project build and `.ZX3` conversion |
| `run_sim.sh`, `zxtres_demo_tb.sv` | Verilator simulation with VGA frame capture |
| `make_mem.py`, `bit_to_zx3.py`, `ppm_to_png.py`, `font8x8_to_hex.py` | Helpers |

## What the program does

`demo.asm` starts at the 80286 reset vector:

1. It measures the CPU clock against the VGA frame rate.
2. It runs 17 instruction tests in real mode, including the checks that
   tell an 80286 from an 8086 or an 80386.
3. It runs the BYTE sieve benchmark (8191 flags, ten passes), timed with the
   hardware cycle counter. It must find 1899 primes.
4. It enters protected mode (LGDT, LIDT, LMSW and a far jump to a selector).
5. It tests protected mode:
   - 24-bit addressing of the RAM above 1 MiB;
   - LAR, LSL, VERR and VERW;
   - a #GP fault on a bad selector.
6. It stays in protected mode, updating an uptime counter, the VGA frame
   number and a spinner.

A failing check shows `[FAIL]` and the ROM offset of the check; `demo.lst`,
written by the build, maps it to the source line. An unexpected exception
prints its vector and stack on the bottom text row and halts.

## Hardware

`zxtres_demo_system.sv` connects the core's normalized bus to:

- 64 KiB of RAM at 0 and 64 KiB at 1 MiB;
- a 64 KiB ROM at F0000h, mirrored at FF0000h for the reset fetch;
- an 80x25 text screen at B8000h;
- I/O ports for a cycle counter, the CPU clock, the VGA frame counter, an
  LED and a scratch register (listed at the top of the file).

Every READY-qualified cycle takes two clocks. The core runs in the baseline
dependency-driven timing policy (`timing_policy_request` 0).

Below the text, a status line drawn in hardware shows the last POST code
(port 80h), CS:IP, HLT, SHUTDOWN, FAULT and the frame counter, so it works
even if the program never runs. Until the CPU writes to the screen, the
screen says so.

- **led[0]** blinks from the 50 MHz oscillator: the core is loaded.
- **led[1]** blinks once per second when every check passed and stays lit if
  any failed.

## Building

```sh
boards/zxtres_plus/build.sh [40|50]    # Vivado 2025.2; 40 MHz CPU by default
boards/zxtres_plus/run_sim.sh          # Verilator, from Linux or WSL
```

`build.sh` writes `build/zxtres_plus/<MHz>mhz/SPK286DEMO.ZX3`, the `.bit`
file, `demo.lst` and the timing and utilization reports. It needs `nasm`
(on PATH, or in WSL when run from Git Bash) and Vivado (`VIVADO`, else
`vivado` on PATH, else `D:\AMD\2025.2`).

`run_sim.sh` simulates the same system for up to 400 ms and fails unless the
demo reports that all its checks passed. It writes the text screen
(`zxtres_demo_screen.txt`), two VGA frames as PNG and the POST log to
`build/zxtres_plus/sim`.

A `.ZX3` core is the bitstream without its `.bit` header, padded to a
multiple of 16 KiB, as `bit2bin_zx3` of github.com/zxtres/tools writes it.

## Loading it on the ZXTRES+

It needs a VGA monitor; this core has no DisplayPort output.

1. Copy `SPK286DEMO.ZX3` to the microSD card.
2. In the ZX Spectrum core, press F5 for the NMI browser, select the file
   and load it. The core goes to a temporary flash slot; the installed cores
   are not changed.
3. Power cycle the board to return to the ZX Spectrum core.

## Font

`font8x8.hex` is made from `font8x8_basic.h` of
[github.com/dhepper/font8x8](https://github.com/dhepper/font8x8) (Daniel
Hepper, after Marcel Sondaar's font from the public-domain IBM VGA fonts),
which is in the public domain:

```sh
boards/zxtres_plus/font8x8_to_hex.py font8x8_basic.h boards/zxtres_plus/font8x8.hex
```
