# Cyclone V CPU timing harness

A CPU-only Quartus build for the DE10-Nano's Cyclone V (5CSEBA6U23I7), the
device of the MiSTer platform. The top is `spk286_native`, which ties the
core's setup and debug ports the way a system integration does; every pin
except `clk` is a virtual pin, so the report covers only the core's own
register-to-register paths. The clock is constrained to 50 MHz, the CPU
clock of the MiSTer PC/AT integration.

```sh
boards/cyclone_v_timing/build.sh [SEED] [TAG]
```

The script copies the RTL into `build/cyclone_v_timing/<TAG>_seed<SEED>/`,
runs `quartus_sh --flow compile` and a `quartus_sta` report in the
`raetro/quartus:mister` container (Quartus Prime Lite 17.0), and writes
`summary.txt`: setup slack at the slow 100 C and -40 C corners, fmax,
resources and the 200 worst paths grouped by source and destination module.
`worst_full.rpt` holds the three worst paths in full.

Fitter results vary with the seed; compare changes over the same seeds.
