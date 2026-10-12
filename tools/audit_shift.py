# SPDX-License-Identifier: MIT
"""Shift arithmetic, ownership and CPU result disposition mutation evidence."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

from tools.rtl_sources import ordered_rtl_sources

ROOT = Path(__file__).resolve().parents[1]
PROBES = (('count-mask',
  'spk286_shift',
  'spk286_shift',
  'remaining_q <= count[4:0]',
  "remaining_q <= {1'b0, count[3:0]}",
  'masked count drives real arithmetic work'),
 ('through-carry',
  'spk286_shift',
  'spk286_shift',
  "kind_q == 2 ? carry_q : 1'b0",
  "kind_q == 2 ? 1'b0 : 1'b0",
  'independent shift result'),
 ('arithmetic-sign',
  'spk286_shift',
  'spk286_shift',
  "next_value[7] = kind_q == 1 ? value_q[0] : kind_q == 3 ? carry_q : kind_q == 7 ? sign_bit : 1'b0;",
  "next_value[7] = kind_q == 1 ? value_q[0] : kind_q == 3 ? carry_q : 1'b0;",
  'independent shift result'),
 ('multi-count-of',
  'spk286_shift',
  'spk286_shift',
  "flags_mask <= 16'h08C5",
  "flags_mask <= 16'h00C5",
  'defined and selected physical flag policy'),
 ('zero-write',
  'spk286_shift',
  'spk286_shift',
  'result_write <= count[4:0] != 0',
  "result_write <= 1'b1",
  'zero count suppresses write disposition'),
 ('captured-width',
  'spk286_shift',
  'spk286_shift',
  'assign sign_bit = byte_q ?',
  'assign sign_bit = operand_byte ?',
  'independent shift result'),
 ('pause',
  'spk286_shift',
  'spk286_shift',
  'end else if (enable) begin',
  'end else begin',
  'masked count drives real arithmetic work'),
 ('cl-source',
  'spk286_micro_executor',
  'spk286_shift_instructions',
  "{8'd0, count_value[7:0]}",
  "{8'd0, count_value[15:8]}",
  'no duplicate or zero-count data write'),
 ('zero-cpu-disposition',
  'spk286_micro_executor',
  'spk286_shift_instructions',
  'result_write_allowed && !result_suppress_q',
  'result_write_allowed',
  'no duplicate or zero-count data write'))



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'shift-audit'
    output.mkdir(parents=True, exist_ok=True)
    sources = ordered_rtl_sources(ROOT)
    originals = {p: p.read_bytes() for p in sources}
    (output/'source.sha256').write_text(''.join(f'{hashlib.sha256(data).hexdigest()}  {p.relative_to(ROOT).as_posix()}\n'
                                              for p,data in originals.items()), encoding='utf-8')
    from tools.shift_reference import vectors as test_vectors
    from tools.shift_instruction_vectors import vectors as direct_vectors
    vector_paths = {}
    for bench, rows in (('spk286_shift',list(test_vectors())),('spk286_shift_instructions',list(direct_vectors()))):
        path=output/(bench+'.txt')
        path.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
        vector_paths[bench]=path
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
        run = subprocess.run(['vvp',str(binary),('+' + ('shift_vectors' if bench == 'spk286_shift' else 'instruction_vectors') + '=' + str(vector_paths[bench]))],cwd=ROOT,capture_output=True,text=True,timeout=600)
        (directory/'run.log').write_text(run.stdout+run.stderr, encoding='utf-8')
        if reason:
            if run.returncode == 0 or reason not in run.stdout+run.stderr:
                raise RuntimeError(f'{name}: intended assertion did not reject mutant')
        elif run.returncode or 'PASS:' not in run.stdout:
            raise RuntimeError(f'{name}: pristine bench failed')
        print(f'SHIFT_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_shift','spk286_shift_instructions'):
        execute('pristine-'+bench,bench)
    for name,module,bench,old,new,reason in PROBES:
        execute(name,bench,(module,old,new),reason)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    print('SHIFT_AUDIT PASS: 9 rejected RTL mutants; 2 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
