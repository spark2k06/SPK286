"""String effects, repeat boundaries and interruption mutation evidence."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

from tools.rtl_sources import ordered_rtl_sources

ROOT = Path(__file__).resolve().parents[1]
PROBES = (('word-stride',
  'spk286_micro_executor',
  'spk286_string_instructions',
  "string_byte ? 16'd1 : 16'd2",
  "string_byte ? 16'd1 : 16'd1",
  'all architectural GPR results and preservation'),
 ('direction',
  'spk286_micro_executor',
  'spk286_string_instructions',
  'architectural_flags[10] ? string_index-string_delta',
  '!architectural_flags[10] ? string_index-string_delta',
  'all architectural GPR results and preservation'),
 ('old-source-offset',
  'spk286_micro_executor',
  'spk286_string_instructions',
  'address_offset <= string_index;',
  'address_offset <= string_index+string_delta;',
  'exact data transaction order, direction and lanes'),
 ('fixed-es-destination',
  'spk286',
  'spk286_string_instructions',
  "string_destination ? 2'd0",
  "string_destination ? 2'd3",
  'exact data transaction order, direction and lanes'),
 ('source-override',
  'spk286',
  'spk286_string_instructions',
  "(segment_override ? override_segment : 2'd3)",
  "(2'd3)",
  'exact data transaction order, direction and lanes'),
 ('repeat-count',
  'spk286_micro_executor',
  'spk286_string_instructions',
  'repeat_kind != 0 && (string_count || string_range_fault)',
  'repeat_kind != 0 && string_range_fault',
  'no extra data transfer'),
 ('fault-count-retention',
  'spk286_micro_executor',
  'spk286_string_instructions',
  'repeat_kind != 0 && (string_count || string_range_fault)',
  'repeat_kind != 0 && string_count',
  'all architectural GPR results and preservation'),
 ('zero-count-entry',
  'spk286_micro_executor',
  'spk286_string_instructions',
  '(string_empty && repeat_kind != 0 && count_value == 0)',
  "(string_empty && 1'b0)",
  'no extra data transfer'),
 ('comparison-stop',
  'spk286_micro_executor',
  'spk286_string_instructions',
  'architectural_flags[6] == (repeat_kind == 2)',
  'architectural_flags[6] != (repeat_kind == 2)',
  'complete ordered data transfers'),
 ('byte-accumulator',
  'spk286_micro_executor',
  'spk286_string_instructions',
  '(string_write_acc && string_byte)',
  "(string_write_acc && 1'b0)",
  'all architectural GPR results and preservation'),
 ('whole-instruction-retirement',
  'spk286',
  'spk286_string_instructions',
  'assign instruction_retired = (raw_retired',
  'assign instruction_retired = repeat_stepped || (raw_retired',
  'complete ordered data transfers'),
 ('iteration-restart-ip',
  'spk286_events',
  'spk286_string_lifecycle',
  '(repeat_boundary || (selected_kind == KIND_FAULT && instruction_active && !fault_new_task)) ? instruction_ip : ip',
  '(selected_kind == KIND_FAULT && instruction_active) ? instruction_ip : ip',
  'full unmasked REP event frame'),
 ('tf-after-element',
  'spk286_micro_executor',
  'spk286_string_lifecycle',
  'assign repeat_stepped = string_continue && string_again;',
  'assign repeat_stepped = repeat_boundary;',
  'event injected during element transfer'),
 ('ss-entire-repeat',
  'spk286_events',
  'spk286_string_boundaries',
  'repeat_ss_inhibit_q <= ss_shadow;',
  "repeat_ss_inhibit_q <= 1'b0;",
  'iteration event identity and handler boundary'),
 ('sti-entire-repeat',
  'spk286_events',
  'spk286_string_boundaries',
  'repeat_sti_inhibit_q <= sti_shadow;',
  "repeat_sti_inhibit_q <= 1'b0;",
  'iteration event identity and handler boundary'),
 ('real-operand-completion',
  'spk286_micro_executor',
  'spk286_string_instructions',
  '(operand_request && operand_done) && !system_operand_request',
  '(operand_request) && !system_operand_request',
  'exact fault producer or single retirement'),
 ('cancel-element-address',
  'spk286_micro_executor',
  'spk286_string_lifecycle',
  "address_override <= 1'b0; address_offset <= 16'd0;",
  "if (reset) address_override <= 1'b0; address_offset <= 16'd0;",
  'cancel invalidates current string address'),
 ('repeat-entry-event',
  'spk286_micro_executor',
  'spk286_string_boundaries',
  '(string_empty && repeat_kind != 0 && count_value != 0)',
  "(string_empty && 1'b0)",
  'iteration event preserves committed elements and remaining count'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'string-audit'
    output.mkdir(parents=True, exist_ok=True)
    rtl_sources = sorted((ROOT/'rtl').glob('*.sv'))
    protected_pkg = ROOT/'rtl/spk286_protected_pkg.sv'
    sources = ordered_rtl_sources(ROOT)
    originals = {p: p.read_bytes() for p in sources}
    (output/'source.sha256').write_text(''.join(f'{hashlib.sha256(data).hexdigest()}  {p.relative_to(ROOT).as_posix()}\n'
                                              for p,data in originals.items()), encoding='utf-8')
    from tools.string_instruction_vectors import records
    rows=list(records()); path=output/'data.txt'
    path.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    def execute(name, bench, replacement=None, reason=None):
        directory = output/name; directory.mkdir(parents=True, exist_ok=True)
        inputs = list(sources)
        if replacement:
            module, old, new = replacement
            original = ROOT/'rtl'/f'{module}.sv'
            text = originals[original].decode()
            if text.count(old) != 1:
                raise RuntimeError(f'{name}: mutation anchor must be unique')
            mutant = directory/original.name; mutant.write_text(text.replace(old,new), encoding='utf-8')
            inputs[inputs.index(original)] = mutant
        binary = directory/'test.vvp'
        build = subprocess.run(['iverilog','-g2012','-Wall','-Irtl','-Isim/unit','-s',bench+'_tb',
                                '-o',str(binary),*map(str,inputs),str(ROOT/'sim/unit'/f'{bench}_tb.sv')],
                               cwd=ROOT,capture_output=True,text=True)
        (directory/'build.log').write_text(build.stdout+build.stderr, encoding='utf-8')
        if build.returncode:
            raise RuntimeError(f'{name}: compile failure is not functional mutation rejection')
        run = subprocess.run(['vvp',str(binary),'+instruction_vectors='+str(path)],cwd=ROOT,capture_output=True,text=True,timeout=60)
        (directory/'run.log').write_text(run.stdout+run.stderr, encoding='utf-8')
        if reason:
            if run.returncode == 0 or reason not in run.stdout+run.stderr:
                raise RuntimeError(f'{name}: intended assertion did not reject mutant')
        elif run.returncode or 'PASS:' not in run.stdout:
            raise RuntimeError(f'{name}: pristine bench failed')
        print(f'STRING_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_string_instructions','spk286_string_lifecycle','spk286_string_boundaries'):
        execute('pristine-'+bench,bench)
    failures = []
    for name,module,bench,old,new,reason in PROBES:
        try:
            execute(name,bench,(module,old,new),reason)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            failures.append(str(error))
            print(f'STRING_MUTATION {name}: INVALID {error}', flush=True)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    if failures:
        raise RuntimeError('; '.join(failures))
    print('STRING_AUDIT PASS: 18 rejected RTL mutants; 3 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
