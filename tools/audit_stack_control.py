"""Reject isolated stack/control faults through exact state, bus and lifecycle assertions."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys
from tools.stack_control_vectors import records

ROOT = Path(__file__).resolve().parents[1]
PROBES = (
    ('sp-width','spk286_stack','spk286_stack_control',"16'hFFFE : 16'd2", "16'hFFFF : 16'd2",'exact GPR result/preservation'),
    ('push-source','spk286_micro_executor','spk286_stack_control','result_operation ? tmp2_q : tmp0_q',
     "result_operation ? tmp2_q : tmp0_q - 16'd2",'write byte'),
    ('pop-sp-order','spk286_micro_executor','spk286_stack_control','move_word ? tmp0_q : operand_gpr_write_data',
     "move_word ? tmp0_q + (destination == 3'd4 ? 16'd2 : 16'd0) : operand_gpr_write_data",'exact GPR result/preservation'),
    ('stack-segment','spk286','spk286_stack_control',"stack_request ? 2'd2 : operand_segment",
     "stack_request ? 2'd3 : operand_segment",'ordered data address'),
    ('return-cursor','spk286','spk286_stack_control','.architectural_ip(debug_ip)',
     '.architectural_ip(debug_fetch_cursor[15:0])','write byte'),
    ('target-next-ip','spk286_micro_executor','spk286_stack_control','architectural_ip + tmp1_q',
     "architectural_ip + tmp1_q + 16'd1",'exact IP and single retirement'),
    ('signed-condition','spk286_condition','spk286_stack_control',"3'd6: base_condition = sign_flag != overflow;",
     "3'd6: base_condition = sign_flag || overflow;",'exact taken/not-taken queue flush count'),
    ('loop-count','spk286_control_decode','spk286_stack_control',"8'hE2: branch_taken = count != 0;",
     "8'hE2: branch_taken = count == 0;",'exact taken/not-taken queue flush count'),
    ('jcxz-count','spk286_control_decode','spk286_stack_control',"opcode == 8'hE1 || opcode == 8'hE2;",
     "opcode == 8'hE1 || opcode == 8'hE2 || opcode == 8'hE3;",'exact GPR result/preservation'),
    ('early-sp','spk286_stack','spk286_stack_lifecycle','request && operand_done','request',
     'resumed exact SP ordering'),
    ('missing-flush','spk286','spk286_stack_lifecycle','assign queue_flush = stream_restart;',
     'assign queue_flush = restart;','taken redirect atomically flushes queue'),
    ('duplicate-retirement','spk286_microsequencer','spk286_stack_control',
     "retired <= 1'b0;\n            if (enable)",
     "retired <= retired;\n            if (enable)",'no duplicated retirement'),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'stack-control-audit'
    output.mkdir(parents=True, exist_ok=True)
    instruction_vectors = output/'instructions.txt'
    vectors=list(records())
    instruction_vectors.write_text(f'{len(vectors):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in vectors))
    sources = [ROOT/'microcode/generated/spk286_microcode_pkg.sv', ROOT/'microcode/generated/spk286_microcode_rom.sv',
               *sorted((ROOT/'rtl').glob('*.sv'))]
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
        argument = f'+instruction_vectors={instruction_vectors}'
        run = subprocess.run(['vvp',str(binary),argument],cwd=ROOT,capture_output=True,text=True,timeout=60)
        (directory/'run.log').write_text(run.stdout+run.stderr, encoding='utf-8')
        if reason:
            if run.returncode == 0 or reason not in run.stdout+run.stderr:
                raise RuntimeError(f'{name}: intended assertion did not reject mutant')
        elif run.returncode or 'PASS:' not in run.stdout:
            raise RuntimeError(f'{name}: pristine bench failed')
        print(f'STACK_CONTROL_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_stack_control','spk286_stack_lifecycle'):
        execute('pristine-'+bench,bench)
    for name,module,bench,old,new,reason in PROBES:
        execute(name,bench,(module,old,new),reason)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    print('STACK_CONTROL_AUDIT PASS: 12 rejected RTL mutants; 2 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
