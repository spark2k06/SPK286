"""Reject focused double-fault RTL mutants using independent directed delivery tests."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from tools.rtl_sources import ordered_rtl_sources

ROOT = Path(__file__).resolve().parents[1]
PROBES = (
    ('no-double-fault', 'spk286_events', 'spk286_double_fault_events',
     'assign entry_double_fault = event_kind == KIND_FAULT &&',
     "assign entry_double_fault = 1'b0 && event_kind == KIND_FAULT &&",
     '286 first-vector classification'),
    ('nonzero-df-error', 'spk286_events', 'spk286_double_fault_events',
     "entry_double_fault ? 16'd0 : (fault_error_valid ? fault_error_code : 16'd0)",
     "entry_double_fault ? 16'd1 : (fault_error_valid ? fault_error_code : 16'd0)",
     'DF zero error code'),
    ('lost-ext', 'spk286_events', 'spk286_double_fault_events',
     "event_vector <= entry_double_fault ? 8'd8 : fault_vector;",
     "event_vector <= entry_double_fault ? 8'd8 : fault_vector; event_external <= 1'b0;",
     'original EXT retained'),
    ('wrong-int-restart', 'spk286_events', 'spk286_double_fault_events',
     'event_ip <= instruction_ip; event_cs <= instruction_cs_q;',
     'event_ip <= ip; event_cs <= instruction_cs_q;',
     'context ledger'),
    ('premature-task-tail', 'spk286_micro_executor', 'spk286_double_fault_cpu',
     '(task_switch_operation && task_commit_done_q && task_service_complete_q)',
     '(task_commit_done_q && task_service_complete_q)',
     'dedicated #DF task once with zero error word'),
    ('ignore-recovery-nmi-fault', 'spk286_events', 'spk286_double_fault_events',
     'assign entry_shutdown = shutdown_nmi_q ||',
     "assign entry_shutdown = 1'b0 ||",
     'failed recovery NMI cannot be retried'),
    ('stale-task-ss-shadow', 'spk286_events', 'spk286_double_fault_events',
     "                    ss_shadow <= 1'b0; sti_shadow <= 1'b0;",
     '                    // injected stale task handoff shadow',
     'SS shadow from a failed task handoff cannot block'),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/double-fault-audit')
    args = parser.parse_args()
    output = args.output.resolve()
    packages = [ROOT / 'rtl/spk286_protected_pkg.sv', ROOT / 'rtl/spk286_tss_pkg.sv']
    sources = ordered_rtl_sources(ROOT)
    originals = {p: p.read_bytes() for p in sources}
    results = []

    def execute(name, bench, mutation=None, reason=None):
        directory = output / name
        directory.mkdir(parents=True, exist_ok=True)
        inputs = list(sources)
        if mutation:
            module, old, new = mutation
            original = ROOT / 'rtl' / (module + '.sv')
            text = originals[original].decode().replace('\r\n', '\n')
            if text.count(old) != 1:
                raise RuntimeError(f'{name}: mutation anchor must occur once')
            changed = directory / original.name
            changed.write_text(text.replace(old, new))
            inputs[inputs.index(original)] = changed
        binary = directory / 'test.vvp'
        build = subprocess.run(['iverilog', '-g2012', '-Irtl', '-Isim/unit', '-s', bench + '_tb',
                                '-o', str(binary), *map(str, inputs),
                                str(ROOT / 'sim/unit' / (bench + '_tb.sv'))],
                               cwd=ROOT, text=True, capture_output=True)
        (directory / 'build.log').write_text(build.stdout + build.stderr)
        if build.returncode:
            raise RuntimeError(f'{name}: compiler failure is not a functional rejection')
        run = subprocess.run(['vvp', str(binary)], cwd=ROOT, text=True, capture_output=True, timeout=90)
        (directory / 'run.log').write_text(run.stdout + run.stderr)
        if reason:
            if run.returncode == 0 or reason not in run.stdout + run.stderr:
                raise RuntimeError(f'{name}: intended assertion did not reject mutant')
        elif run.returncode or 'PASS:' not in run.stdout:
            raise RuntimeError(f'{name}: pristine directed bank failed')
        results.append({'name': name, 'bench': bench, 'status': run.returncode, 'assertion': reason})
        print(f'DOUBLE_FAULT_MUTATION {name}: {"rejected" if reason else "passed"}', flush=True)

    for bench in ('spk286_double_fault_events', 'spk286_double_fault_cpu'):
        execute('pristine-' + bench, bench)
    for name, module, bench, old, new, reason in PROBES:
        execute(name, bench, (module, old, new), reason)
    if any(p.read_bytes() != data for p, data in originals.items()):
        raise RuntimeError('production RTL changed during isolated audit')
    summary = {'validation': 'PASS', 'mutants': len(PROBES), 'pristine': 2, 'results': results,
               'source_sha256': {p.relative_to(ROOT).as_posix(): hashlib.sha256(data).hexdigest()
                                 for p, data in originals.items()}}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f'DOUBLE_FAULT_AUDIT PASS: {len(PROBES)} RTL mutants rejected; 2 pristine banks; production unchanged')


if __name__ == '__main__':
    main()
