"""Decimal/radix arithmetic, full fault frames and service lifetime mutation evidence."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

from tools.rtl_sources import ordered_rtl_sources

ROOT = Path(__file__).resolve().parents[1]
PROBES = (('decimal-low-threshold',
  'spk286_adjust',
  'spk286_adjust',
  'operand[3:0] > 9',
  'operand[3:0] > 10',
  'exact adjusted result and response'),
 ('decimal-subtract-borrow',
  'spk286_adjust',
  'spk286_adjust',
  'high_adjust || (kind[0] && low_adjust && operand[7:0] < 6)',
  'high_adjust',
  'precise adjust FLAGS candidate and mask'),
 ('unpacked-carry',
  'spk286_adjust',
  'spk286_adjust',
  "operand + 16'h0106",
  "operand + 16'h0006",
  'exact adjusted result and response'),
 ('radix-quotient-order',
  'spk286_adjust',
  'spk286_adjust',
  '{next_quotient, next_remainder}',
  '{next_remainder, next_quotient}',
  'exact adjusted result and response'),
 ('packed-high-byte',
  'spk286_adjust',
  'spk286_adjust',
  "{8'd0, next_accumulator}",
  "{8'hFF, next_accumulator}",
  'exact adjusted result and response'),
 ('zero-radix-status',
  'spk286_adjust',
  'spk286_adjust_lifecycle',
  "status({1'b0, operand[7:1]})",
  'status(operand[7:0])',
  'complete unmasked FLAGS/CS/first-prefix-IP frame and unchanged AX'),
 ('zero-radix-frame-mask',
  'spk286_adjust',
  'spk286_adjust_lifecycle',
  "flags_mask <= 16'h08D5",
  "flags_mask <= 16'h00C4",
  'complete unmasked FLAGS/CS/first-prefix-IP frame and unchanged AX'),
 ('zero-radix-write',
  'spk286_adjust',
  'spk286_adjust',
  'result <= operand; result_write <= 0; arithmetic_fault <= 1;\n                    candidate_flags <= status',
  'result <= operand; result_write <= 1; arithmetic_fault <= 1;\n                    candidate_flags <= status',
  'radix-zero fault disposition'),
 ('arithmetic-pause',
  'spk286_adjust',
  'spk286_adjust',
  'end else if (enable) begin',
  "end else if (1'b1) begin",
  'exact adjusted result and response'),
 ('fault-dispatch',
  'spk286_micro_executor',
  'spk286_adjust_lifecycle',
  'assign arithmetic_fault = check_arithmetic && arithmetic_fault_q',
  "assign arithmetic_fault = 1'b0 && check_arithmetic && arithmetic_fault_q",
  'synchronous arithmetic/length exception completes before retirement or INTA'),
 ('fault-cancel-lifetime',
  'spk286_micro_executor',
  'spk286_adjust_lifecycle',
  "arithmetic_fault_q <= 1'b0;",
  "if (reset) arithmetic_fault_q <= 1'b0;",
  'redirect clears arithmetic owned transient state'),
 ('adjust-kind-selection',
  'spk286_control_decode',
  'spk286_adjust_instructions',
  "opcode == 8'h3F ? 3'd3",
  "opcode == 8'h3F ? 3'd2",
  'exact GPR result/preservation'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'adjust-audit'
    output.mkdir(parents=True, exist_ok=True)
    sources = ordered_rtl_sources(ROOT)
    originals = {p: p.read_bytes() for p in sources}
    (output/'source.sha256').write_text(''.join(f'{hashlib.sha256(data).hexdigest()}  {p.relative_to(ROOT).as_posix()}\n'
                                              for p,data in originals.items()), encoding='utf-8')
    from tools.adjust_instruction_vectors import vectors
    rows=list(vectors()); path=output/'adjust-instructions.txt'
    path.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    from tools.adjust_reference import vectors as arithmetic_vectors
    arithmetic=list(arithmetic_vectors()); arithmetic_path=output/'adjust.txt'
    arithmetic_path.write_text(f'{len(arithmetic):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in arithmetic))
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
        run = subprocess.run(['vvp',str(binary),'+instruction_vectors='+str(path),'+adjust_vectors='+str(arithmetic_path)],cwd=ROOT,capture_output=True,text=True,timeout=600)
        (directory/'run.log').write_text(run.stdout+run.stderr, encoding='utf-8')
        if reason:
            if run.returncode == 0 or reason not in run.stdout+run.stderr:
                raise RuntimeError(f'{name}: intended assertion did not reject mutant')
        elif run.returncode or 'PASS:' not in run.stdout:
            raise RuntimeError(f'{name}: pristine bench failed')
        print(f'ADJUST_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_adjust','spk286_adjust_instructions','spk286_adjust_lifecycle'):
        execute('pristine-'+bench,bench)
    for name,module,bench,old,new,reason in PROBES:
        execute(name,bench,(module,old,new),reason)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    print('ADJUST_AUDIT PASS: 12 rejected RTL mutants; 3 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
