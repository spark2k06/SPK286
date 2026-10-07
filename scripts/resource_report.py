#!/usr/bin/env python3
"""Estimate Cyclone V resources with Yosys synth_intel_alm.

Two views are produced, both without I/O buffers:

* modules: the top is synthesized without flattening, with every port kept,
  so each module keeps its own cells. Debug outputs keep their logic, so this
  is an upper bound.
* integrated: a generated wrapper exposes only the functional CPU ports
  (bus, READY, INTR/NMI, HOLD, halt/shutdown), ties execute_enable high and
  the setup ports low, leaves the debug outputs open and is synthesized flat,
  as a consuming design would see it.

Figures are Yosys cell counts (LUTs, arithmetic cells, registers, M10K, MLAB,
DSP), not Quartus ALMs: Quartus packs LUTs into ALMs and optimizes
differently, so its results differ.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.rtl_sources import ordered_rtl_sources  # noqa: E402

COLUMNS = ('luts', 'arith', 'ffs', 'm10k', 'mlab', 'dsp')
HEADINGS = ('LUTs', 'Arithmetic', 'Registers', 'M10K', 'MLAB', 'DSP')


def classify(cell_type):
    """Map a Yosys Cyclone V cell type to a report column, or None."""
    if cell_type == 'MISTRAL_ALUT_ARITH':
        return 'arith'
    if re.fullmatch(r'MISTRAL_ALUT\d|MISTRAL_NOT', cell_type):
        return 'luts'
    if cell_type == 'MISTRAL_FF':
        return 'ffs'
    if cell_type == 'MISTRAL_M10K':
        return 'm10k'
    if cell_type.startswith('MISTRAL_MLAB'):
        return 'mlab'
    if cell_type.startswith('MISTRAL_MUL'):
        return 'dsp'
    return None


def display_name(module):
    """Strip Yosys escaping and parameter suffixes from a module name."""
    name = module.lstrip('\\')
    if name.startswith('$paramod'):
        name = name.split('\\')[1]
    return name


def summarize(stat, top):
    """Return per-module own resources, instance counts and the design total."""
    modules = stat['modules']
    own = {}
    children = {}
    for name, data in modules.items():
        counts = Counter()
        subs = Counter()
        for cell_type, number in data.get('num_cells_by_type', {}).items():
            if cell_type in modules:
                subs[cell_type] += number
                continue
            column = classify(cell_type)
            if column is None:
                raise ValueError(f'unexpected cell type {cell_type} in {name}')
            counts[column] += number
        own[name] = counts
        children[name] = subs
    top_key = next((name for name in modules if display_name(name) == top), None)
    if top_key is None:
        raise ValueError(f'top module {top} not found')
    instances = Counter()

    def visit(name, multiplicity):
        instances[name] += multiplicity
        for child, number in children[name].items():
            visit(child, multiplicity * number)

    visit(top_key, 1)
    rows = Counter()
    per_module = {}
    for name, multiplicity in instances.items():
        label = display_name(name)
        entry = per_module.setdefault(label, {'instances': 0, **{c: 0 for c in COLUMNS}})
        entry['instances'] += multiplicity
        for column in COLUMNS:
            entry[column] += own[name][column] * multiplicity
            rows[column] += own[name][column] * multiplicity
    design = stat.get('design', {}).get('num_cells_by_type')
    if design is not None:
        expected = Counter()
        for cell_type, number in design.items():
            column = classify(cell_type)
            if column is not None:
                expected[column] += number
        if any(expected[c] != rows[c] for c in COLUMNS):
            raise ValueError(f'per-module sum {dict(rows)} differs from design total {dict(expected)}')
    return per_module, {c: rows[c] for c in COLUMNS}


def markdown(per_module, total, top):
    lines = ['| Module | ' + ' | '.join(HEADINGS) + ' |',
             '| --- | ' + ' | '.join('---:' for _ in HEADINGS) + ' |']
    ordered = sorted(per_module.items(), key=lambda item: (-item[1]['luts'], item[0]))
    for name, entry in ordered:
        if not any(entry[c] for c in COLUMNS):
            continue
        label = f'`{name}`' + (f' (x{entry["instances"]})' if entry['instances'] > 1 else '')
        lines.append(f'| {label} | ' + ' | '.join(f'{entry[c]:,}' for c in COLUMNS) + ' |')
    lines.append(f'| **Total `{top}`** | ' + ' | '.join(f'**{total[c]:,}**' for c in COLUMNS) + ' |')
    return '\n'.join(lines) + '\n'


FUNCTIONAL_INPUTS = ('clk', 'reset', 'ready', 'data_in', 'intr', 'nmi', 'hold_request',
                     'historical_enable', 'cpu_boundary', 'timing_read_wait_event')
FUNCTIONAL_OUTPUTS = ('address', 'data_out', 'data_oe', 'bus_valid', 'bus_write', 'bus_bhe_n',
                      'bus_status', 'bus_lock', 'hlda', 'halted', 'shutdown')
PORT = re.compile(r'^\s*(input|output)\s+logic\s*(\[[^\]]+\])?\s*([^;/]*?)\s*,?\s*(//.*)?$')


def ports(path, module):
    """Return (direction, range, name) for every port of a module header."""
    text = path.read_text()
    header = text[text.index(f'module {module} ('):]
    header = header[:header.index(');')]
    result = []
    for line in header.splitlines()[1:]:
        match = PORT.match(line)
        if not match:
            continue
        direction, width, names = match.group(1), match.group(2) or '', match.group(3)
        for name in names.split(','):
            if name.strip():
                result.append((direction, width, name.strip()))
    return result


def wrapper(top, path):
    """Write a wrapper exposing only the functional ports of the top."""
    source = ROOT / ('rtl/timed/spk286_profiled.sv' if top == 'spk286_profiled' else 'rtl/spk286.sv')
    declared, connections = [], []
    for direction, width, name in ports(source, top):
        if name in FUNCTIONAL_INPUTS or name in FUNCTIONAL_OUTPUTS:
            declared.append(f'    {direction} logic {width} {name}')
            connections.append(f'        .{name}({name})')
        elif direction == 'input':
            tie = "'1" if name == 'execute_enable' else "'0"
            connections.append(f'        .{name}({tie})')
        else:
            connections.append(f'        .{name}()')
    path.write_text(f'module {top}_integrated (\n' + ',\n'.join(declared) + '\n);\n'
                    f'    {top} cpu (\n' + ',\n'.join(connections) + '\n    );\nendmodule\n')
    return path


def sources_for(top):
    sources = [str(path) for path in ordered_rtl_sources(ROOT)]
    if top == 'spk286_profiled':
        sources = [s for s in sources if Path(s).name not in ('spk286.sv', 'spk286_events.sv')]
        sources += [str(p) for p in sorted((ROOT / 'rtl/timing').glob('*.sv'))]
        sources += [str(p) for p in sorted((ROOT / 'rtl/timed').glob('*.sv'))]
    return sources


def synthesize(top, sources, stem, flatten):
    script = (f'read_verilog -sv {" ".join(sources)}; '
              f'synth_intel_alm -family cyclonev -top {top} -noiopad{"" if flatten else " -noflatten"}; '
              f'tee -q -o {stem}.json stat -json')
    subprocess.run(['yosys', '-q', '-l', f'{stem}.log', '-p', script], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    return json.loads(Path(f'{stem}.json').read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--top', default='spk286', choices=('spk286', 'spk286_profiled'))
    parser.add_argument('--view', default='modules', choices=('modules', 'integrated'))
    build = Path(os.environ.get('SPK286_BUILD_DIR', ROOT / 'build'))
    parser.add_argument('--output', type=Path, default=build / 'reports')
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    stem = args.output / f'resource_cyclonev_{args.top}_{args.view}'
    sources = sources_for(args.top)
    top = args.top
    if args.view == 'integrated':
        sources.append(str(wrapper(args.top, Path(f'{stem}_wrapper.sv'))))
        top = f'{args.top}_integrated'
    per_module, total = summarize(synthesize(top, sources, stem, args.view == 'integrated'), top)
    if args.view == 'integrated':
        table = markdown({}, total, top)
    else:
        table = markdown(per_module, total, top)
    Path(f'{stem}.md').write_text(table)
    print(table, end='')
    print(f'RESOURCE REPORT PASS: {stem}.md')


if __name__ == '__main__':
    main()
