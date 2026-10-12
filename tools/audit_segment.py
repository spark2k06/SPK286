# SPDX-License-Identifier: MIT
"""Segment selector/cache, invalid encoding and SS interrupt-shadow mutation evidence."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

from tools.rtl_sources import ordered_rtl_sources

ROOT = Path(__file__).resolve().parents[1]
PROBES = (('segment-index',
  'spk286_control_decode',
  'spk286_segment_instructions',
  'group_extension[1:0] : opcode[4:3]',
  "(group_extension[1:0] ^ 2'd1) : opcode[4:3]",
  'exact memory result/preservation'),
 ('segment-selector-source',
  'spk286',
  'spk286_segment_instructions',
  'debug_segment_selectors[decoded_segment_index*16 +: 16]',
  'debug_segment_bases[decoded_segment_index*24 +: 16]',
  'exact memory result/preservation'),
 ('segment-cache-data',
  'spk286_micro_executor',
  'spk286_segment_instructions',
  'assign segment_write_data = tmp0_q;',
  "assign segment_write_data = {8'd0,tmp0_q[7:0]};",
  'exact segment selectors and preservation'),
 ('mov-cs-invalid',
  'spk286',
  'spk286_segment_instructions',
  'operand_reg > 3 || operand_reg == 1',
  'operand_reg > 3',
  'supported segment instruction'),
 ('segment-high-index-invalid',
  'spk286',
  'spk286_segment_instructions',
  "opcode_q == 8'h8C && operand_reg > 3",
  "1'b0 && opcode_q == 8'h8C && operand_reg > 3",
  'supported segment instruction'),
 ('ss-shadow-arm',
  'spk286_events',
  'spk286_segment_lifecycle',
  "if (ss_load) ss_shadow <= 1'b1;",
  "if (ss_load) ss_shadow <= 1'b0;",
  'SS cache and protected stack-pointer update precede event'),
 ('ss-shadow-expiry',
  'spk286_events',
  'spk286_segment_lifecycle',
  "if (opcode_dispatch) begin\n                repeat_ss_inhibit_q <= ss_shadow; repeat_sti_inhibit_q <= sti_shadow;\n                ss_shadow <= 1'b0;",
  'if (opcode_dispatch) begin\n                repeat_ss_inhibit_q <= ss_shadow; repeat_sti_inhibit_q <= sti_shadow;\n                ss_shadow <= ss_shadow;',
  'complete selected event'),
 ('ss-shadow-nmi',
  'spk286_events',
  'spk286_segment_lifecycle',
  '&& !nmi_blocked && !shutdown_reset_only_q && !ss_shadow',
  '&& !nmi_blocked && !shutdown_reset_only_q',
  'SS cache and protected stack-pointer update precede event'),
 ('ss-shadow-tf-arm',
  'spk286_events',
  'spk286_segment_lifecycle',
  'if (ss_load) ss_shadow',
  'if (ss_load && !flags[8]) ss_shadow',
  'SS cache and protected stack-pointer update precede event'),
 # Flushing the queue on a segment write discards bytes that were already
 # prefetched past the SS load, so execution diverges before the frame check.
 ('segment-prefetch-lifetime',
  'spk286',
  'spk286_segment_lifecycle',
  'assign queue_flush = stream_restart;',
  'assign queue_flush = stream_restart || internal_segment_write;',
  'complete selected event'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'segment-audit'
    output.mkdir(parents=True, exist_ok=True)
    sources = ordered_rtl_sources(ROOT)
    originals = {p: p.read_bytes() for p in sources}
    (output/'source.sha256').write_text(''.join(f'{hashlib.sha256(data).hexdigest()}  {p.relative_to(ROOT).as_posix()}\n'
                                              for p,data in originals.items()), encoding='utf-8')
    from tools.segment_instruction_vectors import vectors
    rows=list(vectors()); path=output/'segment.txt'
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
        run = subprocess.run(['vvp',str(binary),'+instruction_vectors='+str(path)],cwd=ROOT,capture_output=True,text=True,timeout=600)
        (directory/'run.log').write_text(run.stdout+run.stderr, encoding='utf-8')
        if reason:
            if run.returncode == 0 or reason not in run.stdout+run.stderr:
                raise RuntimeError(f'{name}: intended assertion did not reject mutant')
        elif run.returncode or 'PASS:' not in run.stdout:
            raise RuntimeError(f'{name}: pristine bench failed')
        print(f'SEGMENT_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_segment_instructions','spk286_segment_lifecycle'):
        execute('pristine-'+bench,bench)
    for name,module,bench,old,new,reason in PROBES:
        execute(name,bench,(module,old,new),reason)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    print('SEGMENT_AUDIT PASS: 10 rejected RTL mutants; 2 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
