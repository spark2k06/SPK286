"""Far pointer, stack-link and context-lifetime mutation evidence."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROBES = (('lds-cache-index',
  'spk286_control_decode',
  'spk286_far_instructions',
  "opcode == 8'hC5 ? 2'd3",
  "opcode == 8'hC5 ? 2'd0",
  'exact segment selector disposition'),
 ('call-link-cs',
  'spk286_control_decode',
  'spk286_far_instructions',
  "group_extension == 3'd3) ? 2'd1",
  "group_extension == 3'd3) ? 2'd2",
  'high write byte'),
 ('pointer-upper-address',
  'spk286_micro_executor',
  'spk286_far_instructions',
  "address_offset <= effective_offset + 16'd2",
  "address_offset <= effective_offset + 16'd4",
  'exact data transaction order, direction and lanes'),
 ('call-stack-precheck',
 'spk286_micro_executor',
 'spk286_call_stack_precheck',
 "stack_pointer[0] && stack_pointer < 16'd4",
 "stack_pointer[0] && stack_pointer < 16'd2",
 'call-frame precheck prevents every stack write'),
 ('return-stack-precheck',
  'spk286_micro_executor',
  'spk286_far_instructions',
  "stack_pointer>=16'hFFFD",
  "stack_pointer>=16'hFFFF",
  'no extra data transfer'),
 ('return-allocation',
  'spk286_micro_executor',
  'spk286_far_instructions',
  'add_allocation_arch ? stack_pointer+allocation_q',
  'add_allocation_arch ? stack_pointer-allocation_q',
  'all architectural GPR results and preservation'),
 ('far-context-selector',
  'spk286_micro_executor',
  'spk286_far_instructions',
  'assign context_cs = tmp1_q',
  'assign context_cs = tmp0_q',
  'exact segment selector disposition'),
 ('return-link-ip',
  'spk286_micro_executor',
  'spk286_far_instructions',
  'if (read_ip) begin tmp0_q <= architectural_ip;',
  "if (read_ip) begin tmp0_q <= architectural_ip-16'd1;",
  'low write byte'),
 ('saved-pointer-offset',
  'spk286_micro_executor',
  'spk286_far_instructions',
  'if (restore_auxiliary) begin tmp0_q <= auxiliary_q;',
  'if (restore_auxiliary) begin tmp0_q <= allocation_q;',
  'all architectural GPR results and preservation'),
 ('memory-only-pointer',
  'spk286',
  'spk286_far_instructions',
  " || opcode_q == 8'hC4 || opcode_q == 8'hC5",
  " || opcode_q == 8'hC5",
  'no extra data transfer'),
 ('cancel-return-allocation',
  'spk286_micro_executor',
  'spk286_far_lifecycle',
  "allocation_valid_q <= 1'b0;",
  "if (reset) allocation_valid_q <= 1'b0;",
  'redirect clears saved far target, allocation and address ownership'),
 ('far-context-offset',
  'spk286_micro_executor',
  'spk286_far_instructions',
  'assign redirect_target = task_commit_redirect ? task_loaded_ip : (context_commit ? tmp0_q : target_q);',
  'assign redirect_target = task_commit_redirect ? task_loaded_ip : (context_commit ? tmp1_q : target_q);',
  'exact pointer/return target address'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'far-audit'
    output.mkdir(parents=True, exist_ok=True)
    packages = [ROOT/'rtl/spk286_protected_pkg.sv', ROOT/'rtl/spk286_tss_pkg.sv']
    sources = [ROOT/'microcode/generated/spk286_microcode_pkg.sv', ROOT/'microcode/generated/spk286_microcode_rom.sv',
               *packages, *sorted(p for p in (ROOT/'rtl').glob('*.sv') if p not in packages)]
    originals = {p: p.read_bytes() for p in sources}
    (output/'source.sha256').write_text(''.join(f'{hashlib.sha256(data).hexdigest()}  {p.relative_to(ROOT).as_posix()}\n'
                                              for p,data in originals.items()), encoding='utf-8')
    from tools.far_instruction_vectors import vectors
    rows=[case.row() for case in vectors()]; path=output/'data.txt'
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
        print(f'FAR_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_far_instructions','spk286_far_lifecycle','spk286_call_stack_precheck'):
        execute('pristine-'+bench,bench)
    for name,module,bench,old,new,reason in PROBES:
        execute(name,bench,(module,old,new),reason)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    print('FAR_AUDIT PASS: 12 rejected RTL mutants; 3 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
