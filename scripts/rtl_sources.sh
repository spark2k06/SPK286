# Shared portable RTL inputs. Source after changing to the repository root.
# Committed generated artifacts must match source before any RTL build begins.
python3 -m tools.microcode.compile_microcode --check
rtl_sources=(microcode/generated/spk286_microcode_pkg.sv
             microcode/generated/spk286_microcode_rom.sv
             microcode/generated/spk286_microcode_sync_rom.sv
             rtl/spk286_protected_pkg.sv
             rtl/spk286_tss_pkg.sv)
for source in rtl/*.sv; do
    [[ "$source" == "rtl/spk286_protected_pkg.sv" || "$source" == "rtl/spk286_tss_pkg.sv" ]] || rtl_sources+=("$source")
done
