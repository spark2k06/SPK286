"""Canonical package-first RTL inputs for portable Python verification tools."""

from pathlib import Path


def ordered_rtl_sources(root: Path) -> list[Path]:
    """Match scripts/rtl_sources.sh, including both generated ROM profiles."""
    packages = [root / 'rtl/spk286_protected_pkg.sv', root / 'rtl/spk286_tss_pkg.sv']
    return [root / 'microcode/generated/spk286_microcode_pkg.sv',
            root / 'microcode/generated/spk286_microcode_rom.sv',
            root / 'microcode/generated/spk286_microcode_sync_rom.sv',
            *packages, *sorted(path for path in (root / 'rtl').glob('*.sv') if path not in packages)]
