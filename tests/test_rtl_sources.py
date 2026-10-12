# SPDX-License-Identifier: MIT
"""Keep mutation audits on the same complete source manifest as shell builds."""

from pathlib import Path
import unittest

from tools.rtl_sources import ordered_rtl_sources

ROOT = Path(__file__).resolve().parents[1]


class RtlSourcesTests(unittest.TestCase):
    def test_complete_unique_manifest(self):
        sources = ordered_rtl_sources(ROOT)
        expected = set((ROOT / 'rtl').glob('*.sv')) | {
            ROOT / 'microcode/generated/spk286_microcode_pkg.sv',
            ROOT / 'microcode/generated/spk286_microcode_rom.sv',
            ROOT / 'microcode/generated/spk286_microcode_sync_rom.sv',
        }
        self.assertEqual(set(sources), expected)
        self.assertEqual(len(sources), len(set(sources)))
        self.assertTrue(all(path.is_file() for path in sources))

    def test_packages_precede_consumers(self):
        sources = ordered_rtl_sources(ROOT)
        cpu = sources.index(ROOT / 'rtl/spk286.sv')
        for name in ('spk286_protected_pkg.sv', 'spk286_tss_pkg.sv'):
            self.assertLess(sources.index(ROOT / 'rtl' / name), cpu)
        self.assertLess(sources.index(ROOT / 'microcode/generated/spk286_microcode_pkg.sv'), cpu)

    def test_shell_manifest_matches(self):
        import subprocess
        result = subprocess.run(['bash', '-c', 'source scripts/rtl_sources.sh; printf "%s\\n" "${rtl_sources[@]}"'],
                                cwd=ROOT, capture_output=True, text=True, check=True)
        names = [line for line in result.stdout.splitlines() if line.endswith('.sv')]
        self.assertEqual(names, [str(path.relative_to(ROOT)) for path in ordered_rtl_sources(ROOT)])


if __name__ == '__main__':
    unittest.main()
