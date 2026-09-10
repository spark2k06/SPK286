"""Data transfer, address lifetime and implicit LOCK mutation evidence."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROBES = (('exchange-writeback',
  'spk286_micro_executor',
  'spk286_data_instructions',
  'write_reg_tmp1 ? tmp1_q :',
  'write_reg_tmp1 ? tmp0_q :',
  'exact GPR result/preservation'),
 ('lea-offset',
  'spk286_micro_executor',
  'spk286_data_instructions',
  'tmp0_q <= effective_offset',
  'tmp0_q <= operand_read_data',
  'exact GPR result/preservation'),
 ('exchange-accumulator',
  'spk286_decoder',
  'spk286_data_instructions',
  "assign source_index = opcode[7:3] == 5'b10010 ||",
  'assign source_index =',
  'exact GPR result/preservation'),
 ('xlat-unsigned-index',
  'spk286_micro_executor',
  'spk286_data_instructions',
  'address_base + tmp0_q',
  'address_base + {{8{tmp0_q[7]}}, tmp0_q[7:0]}',
  'data address/order'),
 ('direct-address-high',
  'spk286_micro_executor',
  'spk286_data_instructions',
  'address_offset <= tmp1_q',
  "address_offset <= {8'd0, tmp1_q[7:0]}",
  'data address/order'),
 ('implicit-lock',
  'spk286',
  'spk286_data_instructions',
  'assign implicit_lock = micro_active',
  "assign implicit_lock = 1'b0 && micro_active",
  'memory exchange owns LOCK throughout physical access'),
 ('lea-invalid-register',
  'spk286',
  'spk286_data_instructions',
  "(opcode_q == 8'h8D || opcode_q == 8'h62 || opcode_q == 8'hC4 || opcode_q == 8'hC5) && operand_register_direct",
  "(opcode_q == 8'h62 || opcode_q == 8'hC4 || opcode_q == 8'hC5) && operand_register_direct",
  'invalid form or word limit blocks without effects'),
 ('address-lifetime',
  'spk286_micro_executor',
  'spk286_data_lifecycle',
  "address_override <= 1'b0; address_offset <= 16'd0;",
  "if (reset) address_override <= 1'b0; address_offset <= 16'd0;",
  'new operand acquired independently; canceled load cannot write AX'))



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'data-audit'
    output.mkdir(parents=True, exist_ok=True)
    sources = [ROOT/'microcode/generated/spk286_microcode_pkg.sv', ROOT/'microcode/generated/spk286_microcode_rom.sv',
               *sorted((ROOT/'rtl').glob('*.sv'))]
    originals = {p: p.read_bytes() for p in sources}
    (output/'source.sha256').write_text(''.join(f'{hashlib.sha256(data).hexdigest()}  {p.relative_to(ROOT).as_posix()}\n'
                                              for p,data in originals.items()), encoding='utf-8')
    from tools.data_instruction_vectors import vectors
    rows=list(vectors()); path=output/'data.txt'
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
        print(f'DATA_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_data_instructions','spk286_data_lifecycle'):
        execute('pristine-'+bench,bench)
    for name,module,bench,old,new,reason in PROBES:
        execute(name,bench,(module,old,new),reason)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    print('DATA_AUDIT PASS: 8 rejected RTL mutants; 2 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
