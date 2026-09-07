# Shared portable RTL inputs. Source after changing to the repository root.
# Committed generated artifacts must match source before any RTL build begins.
python3 -m tools.microcode.compile_microcode --check
rtl_sources=(microcode/generated/spk286_microcode_pkg.sv
             microcode/generated/spk286_microcode_rom.sv rtl/*.sv)
