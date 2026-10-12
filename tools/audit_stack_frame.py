# SPDX-License-Identifier: MIT
"""Stack, frame cursor, generated loop target and signed BOUND mutation evidence."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

from tools.rtl_sources import ordered_rtl_sources

ROOT = Path(__file__).resolve().parents[1]
PROBES = (('pusha-original-sp',
  'spk286_micro_executor',
  'spk286_stack_frame_lifecycle',
  'tmp0_q <= register_state[frame_read_index*16 +: 16];',
  "tmp0_q <= register_state[frame_read_index*16 +: 16] - (frame_read_index == 4 ? 16'd2 : 16'd0);",
  'PUSHA stores original SP'),
 ('popa-destination',
  'spk286_micro_executor',
  'spk286_stack_frame_lifecycle',
  "assign frame_write_index = 3'(operation - spk286_microcode_pkg::MC_WRITE_AX_TMP0);",
  "assign frame_write_index = 3'(operation - spk286_microcode_pkg::MC_WRITE_AX_TMP0) ^ 3'd1;",
  'entire instruction completes before event'),
 ('leave-stack-check',
  'spk286_micro_executor',
  'spk286_stack_frame_lifecycle',
  "check_stack_word && tmp0_q == 16'hFFFF",
  "1'b0 && check_stack_word && tmp0_q == 16'hFFFF",
  'preflight/bounds fault preserves original'),
 ('bound-signed',
  'spk286_micro_executor',
  'spk286_stack_frame_lifecycle',
  '$signed(tmp1_q) < $signed(auxiliary_q) || $signed(tmp1_q) > $signed(tmp0_q)',
  'tmp1_q < auxiliary_q || tmp1_q > tmp0_q',
  'complete selected event'),
 ('bound-even-wrap',
  'spk286_micro_executor',
  'spk286_stack_frame_lifecycle',
  "check_rm32 && effective_offset[0] && effective_offset > 16'hFFFC",
  "check_rm32 && effective_offset > 16'hFFFC",
  'complete selected event'),
 ('enter-allocation',
  'spk286_micro_executor',
  'spk286_stack_frame_lifecycle',
  '(stack_cursor_q - allocation_q)',
  '(stack_cursor_q + allocation_q)',
  'entire instruction completes before event'),
 ('enter-level-mask',
  'spk286_micro_executor',
  'spk286_stack_frame_lifecycle',
  'counter_q <= tmp1_q[4:0];',
  'counter_q <= tmp1_q[5:1];',
  'entire instruction completes before event'),
 ('enter-loop-sense',
  'spk286_micro_executor',
  'spk286_stack_frame_lifecycle',
  '== (counter_q == 0)',
  '== (counter_q != 0)',
  'entire instruction completes before event'),
 ('enter-branch-target',
  'spk286',
  'spk286_stack_frame_lifecycle',
  'counter_branch_request ? counter_branch_target[spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] : dispatch_entry',
  'counter_branch_request ? (counter_branch_target[spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] ^ '
  "spk286_microcode_pkg::MC_ADDR_WIDTH'(1)) : dispatch_entry",
  'ENTER uses SS parent addresses and frame pointer in sequence'),
 ('enter-early-sp',
  'spk286_micro_executor',
  'spk286_stack_frame_lifecycle',
  'assign stack_arch_write = stack_write_sp && !(stack_cursor_valid_q || begin_return_cursor);',
  'assign stack_arch_write = stack_write_sp && !begin_return_cursor;',
  'ENTER preserves architectural SP'),
 ('enter-cancel-cursor',
  'spk286_micro_executor',
  'spk286_stack_frame_lifecycle',
  "stack_cursor_q <= 16'd0; stack_cursor_valid_q <= 1'b0;",
  "stack_cursor_q <= 16'd0; stack_cursor_valid_q <= cancel && !reset && !start ? stack_cursor_valid_q : 1'b0;",
  'cancel retains committed GPRs'),
 ('pusha-preflight',
  'spk286_stack_range',
  'spk286_stack_range',
  "sp[0] && sp < 16'd16",
  "sp < 16'd16",
  'modular word preflight'),
 ('popa-preflight',
  'spk286_stack_range',
  'spk286_stack_range',
  "sp >= 16'hFFF1",
  "sp >= 16'hFFF3",
  'modular word preflight'),
 ('enter-parent-address',
  'spk286_micro_executor',
  'spk286_stack_frame_lifecycle',
  'frame_address_data_select ? frame_address_q : stack_native_offset',
  'frame_address_data_select ? stack_cursor_q : stack_native_offset',
  'ENTER uses SS parent addresses'),
 ('bound-complete-precheck',
  'spk286_micro_executor',
  'spk286_stack_frame_lifecycle',
  "check_rm32 && effective_offset[0] && effective_offset > 16'hFFFC",
  "1'b0 && check_rm32 && effective_offset[0] && effective_offset > 16'hFFFC",
  'BOUND four-byte preflight has no partial memory read'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'stack-frame-audit'
    output.mkdir(parents=True, exist_ok=True)
    packages = [ROOT/'rtl/spk286_protected_pkg.sv', ROOT/'rtl/spk286_tss_pkg.sv']
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
        run = subprocess.run(['vvp',str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=600)
        (directory/'run.log').write_text(run.stdout+run.stderr, encoding='utf-8')
        if reason:
            if run.returncode == 0 or reason not in run.stdout+run.stderr:
                raise RuntimeError(f'{name}: intended assertion did not reject mutant')
        elif run.returncode or 'PASS:' not in run.stdout:
            raise RuntimeError(f'{name}: pristine bench failed')
        print(f'STACK_FRAME_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_stack_frame_lifecycle', 'spk286_stack_range'):
        execute('pristine-'+bench,bench)
    for name,module,bench,old,new,reason in PROBES:
        execute(name,bench,(module,old,new),reason)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    print('STACK_FRAME_AUDIT PASS: 15 rejected RTL mutants; 2 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
