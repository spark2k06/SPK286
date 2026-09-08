"""Unary arithmetic, decoded branches and cached operand lifetime mutation evidence."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROBES = (('neg-direction',
  'spk286_alu_decode',
  'spk286_unary_instructions',
  'assign reverse_operands = unary_neg',
  "assign reverse_operands = 1'b0 && unary_neg",
  'exact FLAGS and preserved bits'),
 ('not-flags',
  'spk286_alu_decode',
  'spk286_unary_instructions',
  "unary_not ? 16'h0000",
  "unary_not ? 16'h08C5",
  'exact FLAGS and preserved bits'),
 ('unary-inc-carry',
  'spk286_alu_decode',
  'spk286_unary_instructions',
  "inc_dec ? 16'h08D4",
  "inc_dec ? 16'h08D5",
  'exact FLAGS and preserved bits'),
 ('complement-constant',
  'spk286_micro_executor',
  'spk286_unary_instructions',
  "constant_ones ? 16'hFFFF",
  "constant_ones ? 16'h00FF",
  'exact memory result/preservation'),
 ('group-neg-target',
  'spk286_control_decode',
  'spk286_unary_instructions',
  'opcode[0] ? spk286_microcode_pkg::MC_ENTRY_NEG_RM16 : spk286_microcode_pkg::MC_ENTRY_NEG_RM8',
  'opcode[0] ? spk286_microcode_pkg::MC_ENTRY_NOT_RM16 : spk286_microcode_pkg::MC_ENTRY_NOT_RM8',
  'exact FLAGS and preserved bits'),
 ('branch-invalid-target',
  'spk286_microsequencer',
  'spk286_microsequencer',
  "!branch_target_valid || {1'b0, branch_target} >= DEPTH",
  "{1'b0, branch_target} >= DEPTH",
  'invalid branch target fails closed'),
 ('branch-range',
  'spk286_microsequencer',
  'spk286_microsequencer',
  "!branch_target_valid || {1'b0, branch_target} >= DEPTH",
  '!branch_target_valid',
  'invalid branch target fails closed'),
 ('branch-disposition',
  'spk286_microsequencer',
  'spk286_microsequencer',
  'end else if (branch_request) begin',
  "end else if (1'b0 && branch_request) begin",
  'branch target preserves macro entry without retirement'),
 ('rearm-address',
  'spk286_operand_decode',
  'spk286_operand_decode',
  "reuse_q <= 1'b1;",
  "reuse_q <= 1'b1; effective_offset <= ea_offset;",
  'rearm pause preserves cached EA and queue'),
 ('invalid-byte-group',
  'spk286',
  'spk286_unary_lifecycle',
  "opcode_q == 8'hFE && operand_reg > 1",
  "1'b0 && opcode_q == 8'hFE && operand_reg > 1",
  'invalid FE faults without displacement or operand effects'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'unary-audit'
    output.mkdir(parents=True, exist_ok=True)
    sources = [ROOT/'microcode/generated/spk286_microcode_pkg.sv', ROOT/'microcode/generated/spk286_microcode_rom.sv',
               *sorted((ROOT/'rtl').glob('*.sv'))]
    originals = {p: p.read_bytes() for p in sources}
    (output/'source.sha256').write_text(''.join(f'{hashlib.sha256(data).hexdigest()}  {p.relative_to(ROOT).as_posix()}\n'
                                              for p,data in originals.items()), encoding='utf-8')
    from tools.unary_instruction_vectors import vectors
    rows=list(vectors()); path=output/'unary.txt'
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
        print(f'UNARY_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_unary_instructions','spk286_microsequencer','spk286_operand_decode','spk286_unary_lifecycle'):
        execute('pristine-'+bench,bench)
    for name,module,bench,old,new,reason in PROBES:
        execute(name,bench,(module,old,new),reason)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    print('UNARY_AUDIT PASS: 10 rejected RTL mutants; 4 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
