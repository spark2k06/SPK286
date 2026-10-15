# SPK286 on the QMTECH XC7A100T core board (openXC7)

A CPU-only synthesis and bring-up harness: SPK286 with the native 80286 bus
adapter (`rtl/native/spk286_native.sv`, contract in `docs/NATIVE_BUS.md`)
for the QMTECH Artix-7 XC7A100T DDR3 core board (`xc7a100tfgg676`), built
entirely with open-source tools. It contains no system logic: the bus leaves
the board on its two headers for a system board to drive.

| File | Content |
| --- | --- |
| `spk286_qmtech_top.sv` | Top level: three-state bus pins, heartbeat LED |
| `gen_xdc.py` | Pin and clock constraints, generated per build |
| `build.sh` | Yosys, nextpnr-xilinx, prjxray bitstream |
| `summary.py` | Utilization and clock results of one build |

## Tools

The flow was validated with:

- YosysHQ [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build)
  release `2026-10-10` (Yosys 0.69), unpacked in `~/opt/oss-cad-suite`;
- the openXC7 toolchain package
  [`2026-10-12`](https://github.com/cavearr/toolchain-openxc7-releases)
  (nextpnr-xilinx `8006fbc`, prjxray, fasm and the chip databases),
  unpacked in `~/opt/openxc7`.

Other locations are given with `OSS_CAD_SUITE` and `OPENXC7`. The Yosys 0.33
that the regression uses is too old for this flow.

## Build

```sh
boards/qmtech_xc7a100t/build.sh            # 32 MHz CLK (16 MHz 80286), seed 1
boards/qmtech_xc7a100t/build.sh 40 2       # 40 MHz CLK, seed 2
```

Output, including `spk286_qmtech.bit`, goes to
`build/qmtech_xc7a100t/<CLK_MHZ>mhz_seed<SEED>/`. `PART` selects another
speed grade (default `xc7a100tfgg676-1`, the slowest).

## Pins

All bus signals are 3.3 V LVCMOS. The header maps come from litex-boards
(`qmtech_artix7_fgg676.py`); J2 uses banks 13 to 15 and J3 banks 34 and 35.

| Header | Signals |
| --- | --- |
| J2 | UART TX/RX on pins 7/8, CLK on pin 22 (H21, clock-capable), D0-D15, RESET, READY#, S0#, S1#, M/IO#, COD/INTA#, HOLD, HLDA, INTR, NMI, PEREQ, BUSY#, ERROR#, PEACK#, HALTED, SHUTDOWN |
| J3 | A0-A23, BHE#, LOCK# |
| Board | 50 MHz oscillator (U22), LEDs on T23 (heartbeat) and R23 (HALTED) |

`gen_xdc.py` holds the exact pin-by-pin order. The LED polarity still has to
be checked on the board.

## Results

`xc7a100tfgg676-1` (slowest speed grade) with the tool versions above,
`spk286_native` with the full core, bus pins on the headers:

| Resource | Used |
| --- | ---: |
| LUT (Yosys cells) | 9,493 (15 % of 63,400) |
| Flip-flops | 4,887 |
| CARRY4 | 524 |
| RAMB18E1 | 1 (microcode ROM) |
| BUFG | 2 |
| I/O pads | 64 |

Maximum CLK frequency reported by nextpnr after routing:

| CLK constraint | Seed 1 | Seed 2 |
| --- | ---: | ---: |
| 32 MHz | 33.80 MHz | - |
| 40 MHz | 33.80 MHz | 37.49 MHz |
| 50 MHz | 33.80 MHz | 37.49 MHz |

A 32 MHz CLK (16 MHz 80286) closes; the result depends on the seed, not on
the constraint. The critical path runs from the register file through the
execution datapath back to a register: 28 logic levels, of which routing
takes 24.6 ns and logic 4.5 ns of 29.6 ns. These are open-source tool
figures for d51725b, before the cpu-timing changes. With Vivado 2025.2,
the CPU-only build in `boards/artix7_timing` reaches 54.27 MHz for d51725b and
61.29 MHz for ef62028 on the xc7a100tfgg484-2. An openXC7 build takes
about 14 minutes and 1.5 GB of memory.
