# SPDX-License-Identifier: MIT
"""Iterative arithmetic, fixed-register disposal and cancellation mutation evidence."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

from tools.rtl_sources import ordered_rtl_sources

ROOT = Path(__file__).resolve().parents[1]
PROBES = (('product-sign',
  'spk286_muldiv',
  'spk286_muldiv',
  "negative_q ? 32'd0-next_product : next_product",
  'next_product',
  'exact integer result and response'),
 ('quotient-sign',
  'spk286_muldiv',
  'spk286_muldiv',
  "negative_q ? 16'd0-next_quotient[15:0] : next_quotient[15:0]",
  'next_quotient[15:0]',
  'exact integer result and response'),
 ('remainder-sign',
  'spk286_muldiv',
  'spk286_muldiv',
  "remainder_negative_q ? 16'd0-reduced_remainder[15:0] : reduced_remainder[15:0]",
  'reduced_remainder[15:0]',
  'exact integer result and response'),
 ('divide-overflow-boundary',
  'spk286_muldiv',
  'spk286_muldiv',
  'signed_q ? next_quotient >',
  'signed_q ? next_quotient >=',
  'precise quotient-overflow/zero-divisor disposition'),
 ('zero-divisor',
  'spk286_muldiv',
  'spk286_muldiv',
  'arithmetic_fault<=zero_divisor_q || (overflow && !byte_overflow_accept)',
  'arithmetic_fault<=!zero_divisor_q && (overflow && !byte_overflow_accept)',
  'precise quotient-overflow/zero-divisor disposition'),
 ('byte-quotient-remainder',
  'spk286_muldiv',
  'spk286_muldiv',
  '{signed_remainder[7:0],signed_quotient[7:0]}',
  '{signed_quotient[7:0],signed_remainder[7:0]}',
  'exact integer result and response'),
 ('multiply-upper-flags',
  'spk286_muldiv',
  'spk286_muldiv',
  'status(high_product,byte_q)',
  'status(signed_product[15:0],byte_q)',
  'precise integer FLAGS candidate and mask'),
 ('word-high-result',
  'spk286_muldiv',
  'spk286_muldiv',
  "result_high<=byte_q ? 16'd0 : signed_product[31:16]",
  "result_high<=byte_q ? 16'd0 : signed_product[15:0]",
  'exact integer result and response'),
 ('pause-calculation',
  'spk286_muldiv',
  'spk286_muldiv',
  'end else if (enable) begin',
  "end else if (1'b1) begin",
  'exact integer result and response'),
 ('low-result-target',
  'spk286_micro_executor',
  'spk286_muldiv_instructions',
  "write_result_dx ? 3'd2 : 3'd0",
  "write_result_dx ? 3'd2 : 3'd1",
  'exact GPR result/preservation'),
 ('high-result-value',
  'spk286_micro_executor',
  'spk286_muldiv_instructions',
  'write_result_dx ? auxiliary_q : tmp2_q',
  'write_result_dx ? tmp2_q : tmp2_q',
  'exact GPR result/preservation'),
 ('fault-result-suppression',
  'spk286_micro_executor',
  'spk286_muldiv_instructions',
  '(write_result_ax || write_result_dx) && !result_suppress_q',
  '(write_result_ax || write_result_dx)',
  'exact GPR result/preservation'),
 ('cancel-high-result',
  'spk286_micro_executor',
  'spk286_muldiv_lifecycle',
  "arithmetic_fault_q <= 1'b0; result_high_pending_q <= 1'b0;",
  "arithmetic_fault_q <= 1'b0; if (reset) result_high_pending_q <= 1'b0;",
  'redirect clears response, divide fault and high result ownership'),
 ('captured-kind',
  'spk286_control_decode',
  'spk286_muldiv_instructions',
  'assign muldiv_kind = group_extension[1:0]',
  "assign muldiv_kind = {group_extension[1],1'b0}",
  'exact GPR result/preservation'))
PROBES += (
 ('byte-overflow-finite-result','spk286_muldiv','spk286_muldiv',
  'result_low<=byte_overflow_accept ?', "result_low<=1'b0 ?", 'exact integer result and response'),
 ('byte-overflow-acceptance','spk286_muldiv','spk286_muldiv',
  "overflow && byte_corrected_quotient == 8'h80", "overflow && byte_corrected_quotient == 8'h81", 'exact integer result and response'),
 ('byte-overflow-normalization','spk286_muldiv','spk286_muldiv',
  'dividend[15:0] ^ {16{dividend_negative}}', 'dividend[15:0]', 'exact integer result and response'),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'muldiv-audit'
    output.mkdir(parents=True, exist_ok=True)
    sources = ordered_rtl_sources(ROOT)
    originals = {p: p.read_bytes() for p in sources}
    (output/'source.sha256').write_text(''.join(f'{hashlib.sha256(data).hexdigest()}  {p.relative_to(ROOT).as_posix()}\n'
                                              for p,data in originals.items()), encoding='utf-8')
    from tools.muldiv_instruction_vectors import vectors
    rows=list(vectors()); path=output/'muldiv-instructions.txt'
    path.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    from tools.muldiv_reference import vectors as arithmetic_vectors
    arithmetic=list(arithmetic_vectors()); arithmetic_path=output/'muldiv.txt'
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
        run = subprocess.run(['vvp',str(binary),'+instruction_vectors='+str(path),'+muldiv_vectors='+str(arithmetic_path)],cwd=ROOT,capture_output=True,text=True,timeout=600)
        (directory/'run.log').write_text(run.stdout+run.stderr, encoding='utf-8')
        if reason:
            if run.returncode == 0 or reason not in run.stdout+run.stderr:
                raise RuntimeError(f'{name}: intended assertion did not reject mutant')
        elif run.returncode or 'PASS:' not in run.stdout:
            raise RuntimeError(f'{name}: pristine bench failed')
        print(f'MULDIV_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_muldiv','spk286_muldiv_instructions','spk286_muldiv_lifecycle'):
        execute('pristine-'+bench,bench)
    for name,module,bench,old,new,reason in PROBES:
        execute(name,bench,(module,old,new),reason)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    print('MULDIV_AUDIT PASS: 17 rejected RTL mutants; 3 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
