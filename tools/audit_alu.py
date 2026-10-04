"""Require isolated ALU/datapath mutants to fail an intended assertion."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys
from tools.alu_reference import write_vectors
from tools.alu_instruction_vectors import write_vectors as write_instruction_vectors

from tools.rtl_sources import ordered_rtl_sources

ROOT = Path(__file__).resolve().parents[1]
PROBES = (
    ('carry', 'spk286_alu', 'spk286_alu', 'candidate_flags[0] = operand_byte ? extended_result[8] : extended_result[16];',
     'candidate_flags[0] = operand_byte ? ~extended_result[8] : ~extended_result[16];', 'ALU flag bit=0'),
    ('word-parity', 'spk286_alu', 'spk286_alu', '~^result[7:0]', '~^result[15:0]', 'ALU flag bit=2'),
    ('overflow', 'spk286_alu', 'spk286_alu', '(sign_a ^ sign_result) &', "1'b0 &", 'ALU flag bit=11'),
    ('auxiliary-carry', 'spk286_alu', 'spk286_alu', 'operand_a[4] ^ operand_b[4] ^ result[4]', "1'b0", 'ALU flag bit=4'),
    ('subtraction-order', 'spk286_alu', 'spk286_alu', "{1'b0, a} - {1'b0, b}",
     "{1'b0, b} - {1'b0, a}", 'ALU result'),
    ('carry-input', 'spk286_alu', 'spk286_alu', 'assign carry = carry_in &&', "assign carry = 1'b0 &&", 'ALU result'),
    ('cmp-write', 'spk286_alu_decode', 'spk286_alu_instructions', "assign write_result = adjust_instruction || (kind != 3'd7 && !test_instruction);",
     "assign write_result = adjust_instruction || !test_instruction;", 'exact GPR result/preservation'),
    ('all-flags', 'spk286_micro_executor', 'spk286_alu_instructions',
     'flags_mask_q <= adjust_complete ? adjust_mask : shift_complete ? shift_mask : (decoded_flags_mask & ~decoded_undefined_mask);', "flags_mask_q <= adjust_complete ? adjust_mask : shift_complete ? shift_mask : 16'h7FD5;", 'exact FLAGS and preserved bits'),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'alu-audit'
    output.mkdir(parents=True, exist_ok=True)
    alu_vectors = output/'alu.txt'; instruction_vectors = output/'instructions.txt'
    write_vectors(alu_vectors); write_instruction_vectors(instruction_vectors)
    sources = ordered_rtl_sources(ROOT)
    originals = {p: p.read_bytes() for p in sources}
    (output/'source.sha256').write_text(''.join(f'{hashlib.sha256(data).hexdigest()}  {p.relative_to(ROOT).as_posix()}\n'
                                              for p,data in originals.items()), encoding='utf-8')
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
        argument = f'+alu_vectors={alu_vectors}' if bench == 'spk286_alu' else f'+instruction_vectors={instruction_vectors}'
        run = subprocess.run(['vvp',str(binary),argument],cwd=ROOT,capture_output=True,text=True,timeout=60)
        (directory/'run.log').write_text(run.stdout+run.stderr, encoding='utf-8')
        if reason:
            if run.returncode == 0 or reason not in run.stdout+run.stderr:
                raise RuntimeError(f'{name}: intended assertion did not reject mutant')
        elif run.returncode or 'PASS:' not in run.stdout:
            raise RuntimeError(f'{name}: pristine bench failed')
        print(f'ALU_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_alu','spk286_alu_instructions'):
        execute('pristine-'+bench,bench)
    for name,module,bench,old,new,reason in PROBES:
        execute(name,bench,(module,old,new),reason)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    print('ALU_AUDIT PASS: 8 rejected RTL mutants; 2 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
