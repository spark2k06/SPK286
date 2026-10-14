#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Summarize a boards/cyclone_v_timing run: slack, fmax, resources and the
worst setup paths grouped by source and destination module."""
from collections import Counter
from pathlib import Path
import re
import sys


def find(run, name):
    for path in (run / name, run / 'output_files' / name):
        if path.exists():
            return path.read_text(errors='replace')
    return ''


def module(node):
    # "spk286_alu:alu|result_q[3]" -> "alu"; the top level has no prefix.
    parts = [part.split(':')[-1] for part in node.split('|')[:-1]]
    return '.'.join(parts) or 'spk286'


def main():
    run = Path(sys.argv[1])
    print('run:', run.name)
    sta = find(run, 'spk286_timing.sta.summary')
    for corner in ('100C', '-40C'):
        match = re.search(rf"Slow 1100mV {corner} Model Setup 'clk'\s*\nSlack\s*:\s*(-?[0-9.]+)", sta)
        print(f'setup slack slow {corner}:', match.group(1) if match else 'n/a')
    fmax = re.search(r';\s*([0-9.]+) MHz\s*;\s*([0-9.]+) MHz\s*;\s*clk\s*;', find(run, 'fmax.rpt'))
    print('fmax slow 100C:', fmax.group(1) + ' MHz' if fmax else 'n/a')
    fit = find(run, 'spk286_timing.fit.summary')
    for label in ('Logic utilization', 'Total registers', 'Total RAM Blocks', 'Total DSP Blocks'):
        match = re.search(re.escape(label) + r'[^:]*:\s*(.+)', fit)
        print(f'{label}:', match.group(1).strip() if match else 'n/a')
    rows = re.findall(r'^;\s*(-?[0-9.]+)\s*;\s*(\S+)\s*;\s*(\S+)\s*;', find(run, 'worst.rpt'), re.M)
    groups = Counter()
    worst = {}
    for slack, source, destination in rows:
        key = f'{module(source)} -> {module(destination)}'
        groups[key] += 1
        worst.setdefault(key, float(slack))
    print(f'worst {len(rows)} paths by module:')
    for key, count in sorted(groups.items(), key=lambda item: worst[item[0]]):
        print(f'  {worst[key]:7.3f} ns  x{count:<3d} {key}')


if __name__ == '__main__':
    main()
