# SPK286 ZXTRES+ demo with openXC7

The ZXTRES+ bring-up demo of `boards/zxtres_plus` built entirely with
open-source tools: Yosys, nextpnr-xilinx and the prjxray bitstream tools of
the openXC7 package, for the ZXTRES+ (`xc7a100tfgg484-2`). The RTL, the
program, the font and the pins are those of `boards/zxtres_plus`; see its
README for what the demo does and how to load a `.ZX3` core.

| File | Content |
| --- | --- |
| `zxtres_demo_top_openxc7.sv` | Board top with a PLLE2_BASE (nextpnr-xilinx places it) instead of the MMCM |
| `gen_xdc.py` | nextpnr constraints from `boards/zxtres_plus/zxtres_demo.xdc` |
| `build.sh` | Yosys, nextpnr-xilinx, prjxray bitstream, checks, `.ZX3` |
| `compress_bitstream.py` | Optional (`COMPRESS=1`) Vivado-style compression; a core built with it did not start on the board |
| `zxtres_bitstream.py` | Adds the ZXTRES+ flash read settings to the bitstream |
| `check_readback.py` | Decodes the prjxray bitstream and compares it with the placed design |
| `decode_frames.py` | Models the configuration logic to compare two bitstreams frame by frame |
| `bit_packets.py` | Lists the configuration packets of a `.bit` file |
| `summary.py` | Utilization and clock results; fails when a clock misses its constraint |
| `run_netlist_sim.sh` | Simulates the Yosys netlist and compares it with the RTL simulation |
| `xc7_bram_sim.sv`, `strip_cells.py` | Behavioural RAMB18E1/RAMB36E1 for that simulation |

## Tools

The flow was validated with the tools of `boards/qmtech_xc7a100t`:

- YosysHQ [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build)
  release `2026-10-10` (Yosys 0.69), unpacked in `~/opt/oss-cad-suite`;
- the openXC7 toolchain package
  [`2026-10-12`](https://github.com/cavearr/toolchain-openxc7-releases)
  (nextpnr-xilinx, prjxray and the chip databases, including
  `xc7a100tfgg484-2`), unpacked in `~/opt/openxc7`.

Other locations are given with `OSS_CAD_SUITE` and `OPENXC7`. `nasm`,
`python3` and Verilator come from PATH. Run the scripts from Linux or WSL.

## Build and checks

```sh
boards/zxtres_plus_openxc7/build.sh [33|31|40] [SEED]   # 33.333 MHz CPU by default
boards/zxtres_plus_openxc7/run_netlist_sim.sh            # Yosys netlist vs RTL
```

`build.sh` writes `build/zxtres_plus_openxc7/<MHz>mhz_seed<SEED>/`, with
`SPK286DEMO.ZX3`, `zxtres_demo.bit`, `demo.lst`, the logs and
`summary.txt`. It fails unless:

- every clock meets its constraint in nextpnr's timing analysis;
- the prjxray bitstream, read back with `bitread` and decoded with prjxray's
  disassembler, holds exactly the features nextpnr placed and routed
  (`readback.txt`). Features that set no bit are equal to an unused
  setting and are not counted;
- the final bitstream, with the ZXTRES+ header, writes the same frames at
  every address as the prjxray one (`frames.txt`).

nextpnr-xilinx's delay model is not signoff-grade, so the default CPU
clock keeps a margin: 33.333 MHz, where the routed design reaches 37 to
42 MHz depending on the run. The demo measures and shows the real clock.

`run_netlist_sim.sh` runs the RTL simulation of `boards/zxtres_plus`, then
synthesizes `zxtres_demo_system` with the same Yosys options, simulates the
netlist with Yosys's Xilinx cell models and the same testbench, and fails
unless the POST code sequence and both captured VGA frames are identical.
It checks the synthesis; the board top only adds the PLL and resets.
Yosys's `cells_sim.v` declares RAMB18E1 and RAMB36E1 without behaviour, so a
netlist simulated with it reads zeros from every block RAM; the script
replaces them with `xc7_bram_sim.sv`, which models what synth_xilinx emits
here and stops on any other configuration.

## Bitstream for the ZXTRES+

ZXTRES+ cores are built with `SPI_BUSWIDTH 4`, `SPI_32BIT_ADDR YES` and
compression; `xc7frames2bit` writes none of these options. The core is not
compressed here: at 3.8 MB the ZXTRES+ loads it as is, and on a board it
passes the 22 checks.

`compress_bitstream.py` (`COMPRESS=1`) rewrites the frames of the prjxray
bitstream the way Vivado's compressed bitstreams write them: frames with the
same contents, within a block type, are written once and copied to their
other addresses with the multiple frame write (CMD MFW and MFWR, with eight
NOOPs after each in block RAM content), the others in runs within a column
followed by one pad frame, and CTL1 bit 12 is set around the frame writes.
The core shrinks from 3.8 MB to about 1.45 MB. **It does not start on the
board**, although `decode_frames.py` shows it writing the same frames as the
uncompressed bitstream: the same design, routed by Vivado and converted
through this flow, boots uncompressed and gives a black screen compressed;
the nextpnr core, compressed, showed the screen but the CPU never ran (POST
00), and uncompressed it passes. The model of the configuration logic that
`decode_frames.py` uses is therefore not enough to certify a compressed
bitstream; what the board does differently is not known.

`zxtres_bitstream.py` then inserts the flash read settings Vivado writes, at
the same place: after the sync word, BSPI = `0000026Ch` (quad output read
with 4-byte addresses) and the BSPI_READ command, before the first CRC
reset, with the dummy words before the sync word padded to Vivado's 74.
`bit_packets.txt` lists the result; up to the first frame write it matches
the Vivado bitstream of `boards/zxtres_plus` word for word.

prjxray's `bitread` does not follow multiple frame writes, so
`decode_frames.py` models the frame buffer, WCFG, MFW and the frame address
order and gives the contents of every address. On Vivado's compressed and
uncompressed bitstreams of the same routed demo it decodes identical frames
at all 9,448 addresses, and Vivado's compressed core boots; see above for
what that does not prove.

The uncompressed openXC7 core (33.333 MHz, seed 1) boots on a ZXTRES+ and
passes the 22 checks, with the CPU measured at 33.333 MHz.
