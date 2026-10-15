#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Summarize a boards/artix7_timing run: slack, fmax, logic levels, resources
and the worst setup paths grouped by source and destination module."""
from collections import Counter
from pathlib import Path
import csv
import re
import sys


def module(cell):
    # "alu/result_q_reg[3]" -> "alu"; the top level has no prefix.
    return '.'.join(cell.split('/')[:-1]) or 'spk286'


def main():
    run = Path(sys.argv[1])
    print('run:', run.name)
    result = dict(line.split(' ', 1) for line in (run / 'result.txt').read_text().splitlines())
    period, wns = float(result['period']), float(result['wns'])
    print('part:', result['part'])
    print(f'setup slack: {wns:.3f} ns at {period:.3f} ns')
    print(f"hold slack: {float(result['whs']):.3f} ns")
    print(f'fmax: {1000 / (period - wns):.2f} MHz')
    utilization = (run / 'utilization.rpt').read_text(errors='replace')
    for label in ('Slice LUTs', 'Slice Registers', 'Block RAM Tile', 'DSPs'):
        match = re.search(r'^\|\s*' + re.escape(label) + r'\*?\s*\|\s*([0-9.]+)\s*\|', utilization, re.M)
        print(f'{label}:', match.group(1) if match else 'n/a')
    with open(run / 'worst.csv', newline='') as handle:
        rows = list(csv.DictReader(handle))
    if rows:
        print('logic levels of the worst path:', rows[0]['levels'])
    groups = Counter()
    worst = {}
    for row in rows:
        key = f"{module(row['startpoint'])} -> {module(row['endpoint'])}"
        groups[key] += 1
        worst.setdefault(key, float(row['slack']))
    print(f'worst {len(rows)} paths by module:')
    for key, count in sorted(groups.items(), key=lambda item: worst[item[0]]):
        print(f'  {worst[key]:7.3f} ns  x{count:<3d} {key}')


if __name__ == '__main__':
    main()
