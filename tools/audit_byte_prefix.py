"""Byte lanes, register halves and prefix/event ownership mutation evidence."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

from tools.rtl_sources import ordered_rtl_sources

ROOT = Path(__file__).resolve().parents[1]
PROBES = (
    ('byte-write-lane','spk286_biu','spk286_biu_width_io',
     "{write_data_q[7:0], 8'h00}","{write_data_q[15:8], 8'h00}", 'captured write value and selected lane'),
    ('byte-enable','spk286_biu','spk286_biu_width_io',
     'byte_q ? !address_q[0] : second_q', 'byte_q ? address_q[0] : second_q', 'address, lanes and direction held'),
    ('high-byte-alias','spk286_operand','spk286_operand_byte',
     "request_byte ? {1'b0, register_index[1:0]} : register_index", 'register_index', 'byte read selects independent low/high alias'),
    ('preserve-other-half','spk286_registers','spk286_operand_byte',
     'if (write_byte)', "if (1'b0)", 'byte write preserves every other architectural byte'),
    ('prefix-leak','spk286_instruction_context','spk286_prefix',
     'segment_override <= 0;', 'segment_override <= complete ? segment_override : 0;', 'prefix context cleared at retirement'),
    ('prefix-fault-ip','spk286_events','spk286_prefix',
     '(repeat_boundary || (selected_kind == KIND_FAULT && instruction_active && !fault_new_task)) ? instruction_ip : ip', 'ip', 'restart IP includes the first prefix'),
    ('lock-ownership','spk286_biu','spk286_prefix',
     'lock_request || lock_chain_q', 'lock_chain_q', 'LOCK read accepted'),
)



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'byte-prefix-audit'
    output.mkdir(parents=True, exist_ok=True)
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
        print(f'BYTE_PREFIX_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_biu_width_io','spk286_operand_byte','spk286_prefix'):
        execute('pristine-'+bench,bench)
    for name,module,bench,old,new,reason in PROBES:
        execute(name,bench,(module,old,new),reason)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    print('BYTE_PREFIX_AUDIT PASS: 7 rejected RTL mutants; 3 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
