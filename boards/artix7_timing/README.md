# Artix-7 CPU timing harness

A CPU-only AMD Vivado build for Xilinx 7-series parts, the counterpart of
`boards/cyclone_v_timing`. The top is `spk286_native`, which ties the core's
setup and debug ports the way a system integration does. It is synthesized
out of context: the ports get no I/O buffers and `clk` is assumed to come
from a global clock buffer, so the report covers only the core's own
register-to-register paths.

```sh
boards/artix7_timing/build.sh [PART] [CLK_MHZ] [TAG]
```

`PART` defaults to `xc7a100tfgg484-2`, the ZXTRES+ device, and `CLK_MHZ` to
50. The script copies the RTL into
`build/artix7_timing/<TAG>_<PART>_<CLK_MHZ>mhz/` and runs synthesis,
`opt_design`, `place_design`, `phys_opt_design` and `route_design` in Vivado
batch mode. It writes `summary.txt` with:

- the setup and hold slack;
- fmax;
- the logic levels of the worst path;
- the resources;
- the 200 worst paths grouped by source and destination module.

`worst_full.rpt` holds the three worst paths in full. `VIVADO` names the
Vivado executable (`vivado.bat` on Windows). It defaults to `vivado` on
`PATH`, then to an installation under `D:\AMD\2025.2`. The free Vivado ML
Standard edition covers these parts. A run takes about seven minutes.

Vivado stops optimizing once the constraint is met, so fmax at an easy
constraint understates what the core can reach. To find the limit, constrain
above the expected fmax.
