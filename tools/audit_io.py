"""Scalar and repeated port transfer ownership mutation evidence."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROBES = (('captured-port',
  'spk286_micro_executor',
  'spk286_scalar_io',
  'assign io_port = tmp1_q;',
  'assign io_port = tmp0_q;',
  'physical I/O address sequence includes A16 carry'),
 ('port-immediate-extension',
  'spk286_micro_executor',
  'spk286_scalar_io',
  "port_immediate ? {8'd0, byte_data} : port_register",
  'port_immediate ? {{8{byte_data[7]}}, byte_data} : port_register',
  'physical I/O address sequence includes A16 carry'),
 ('dx-port-source',
  'spk286',
  'spk286_scalar_io',
  '.port_register(register_state[32 +: 16])',
  '.port_register(register_state[48 +: 16])',
  'physical I/O address sequence includes A16 carry'),
 ('word-port-width',
  'spk286_micro_executor',
  'spk286_scalar_io',
  'io_byte ||',
  'io_transfer ||',
  'exact I/O byte lane'),
 ('port-bus-type',
  'spk286',
  'spk286_string_io',
  '.data_io(io_transfer)',
  ".data_io(1'b0)",
  'exact data transaction order, direction and lanes'),
 ('output-direction',
  'spk286_micro_executor',
  'spk286_string_io',
  'io_write || string_store',
  'string_store',
  'exact data transaction order, direction and lanes'),
 ('output-payload',
  'spk286_micro_executor',
  'spk286_string_io',
  ': tmp0_q)));',
  ": 16'd0)));",
  'low write byte'),
 ('port-completion-dependency',
  'spk286_micro_executor',
  'spk286_string_io',
  'assign operation_done =',
  'assign operation_done = io_transfer ||',
  'exact fault producer or single retirement'),
 ('input-result-ownership',
  'spk286_micro_executor',
  'spk286_string_io',
  'assign read_tmp1 = string_read1',
  'assign read_tmp1 = io_read || string_read1',
  'exact fault producer or single retirement'),
 ('odd-port-address-carry',
  'spk286_biu',
  'spk286_string_io',
  "address_q <= address_q + 24'd1;",
  "address_q <= io_q ? {8'd0,address_q[15:0] + 16'd1} : address_q + 24'd1;",
  'exact data transaction order, direction and lanes'),
 ('source-override',
  'spk286',
  'spk286_string_io',
  "(segment_override ? override_segment : 2'd3)",
  "(2'd3)",
  'exact data transaction order, direction and lanes'),
 ('fixed-es-destination',
  'spk286',
  'spk286_string_io',
  "string_destination ? 2'd0",
  "string_destination ? 2'd3",
  'exact data transaction order, direction and lanes'),
 ('input-fault-count',
  'spk286_micro_executor',
  'spk286_string_io',
  'repeat_kind != 0 && (string_count || string_range_fault)',
  'repeat_kind != 0 && string_count',
  'all architectural GPR results and preservation'),
 ('zero-count-no-port',
  'spk286_micro_executor',
  'spk286_string_io',
  '(string_empty && repeat_kind != 0 && count_value == 0)',
  "(string_empty && 1'b0)",
  'no extra data transfer'),
 ('repeat-count',
  'spk286_micro_executor',
  'spk286_string_io',
  'repeat_kind != 0 && (string_count || string_range_fault)',
  'repeat_kind != 0 && string_range_fault',
  'no extra data transfer'),
 ('cancel-drains-accepted-port',
  'spk286_biu',
  'spk286_string_io_lifecycle',
  "if (data_active_q) canceled_q <= 1'b1;",
  "if (data_active_q) begin canceled_q <= 1'b1; data_active_q <= 1'b0; end",
  'cancel drains accepted port effects without replay'),
 ('repeat-port-retention',
  'spk286_micro_executor',
  'spk286_string_io',
  "if (string_continue) address_override <= 1'b0;",
  "if (string_continue) begin address_override <= 1'b0; temporary_valid_q[1] <= 1'b0; end",
  'exact fault producer or single retirement'),
 ('input-before-destination-fault',
  'spk286_micro_executor',
  'spk286_string_io',
  'assign io_read = allowed && !io_privilege_fault && temporary_valid_q[1]',
  "assign io_read = allowed && !io_privilege_fault && register_state[112 +: 16] != 16'hFFFF && temporary_valid_q[1]",
  'exact fault producer or single retirement'),
 ('repeated-input-fresh-sample',
  'spk286_micro_executor',
  'spk286_string_io_lifecycle',
  'tmp0_q <= operand_read_data;',
  'if (!io_read || !temporary_valid_q[0]) tmp0_q <= operand_read_data;',
  'each repeated input commits its own accepted sample low byte'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('SPK286_BUILD_DIR', 'build')))
    args = parser.parse_args()
    subprocess.run([sys.executable, '-m', 'tools.microcode.compile_microcode', '--check'], check=True)
    output = args.build_dir.resolve()/'io-audit'
    output.mkdir(parents=True, exist_ok=True)
    rtl_sources = sorted((ROOT/'rtl').glob('*.sv'))
    # Match scripts/rtl_sources.sh: packages must precede their users in Icarus.
    packages = [ROOT/'rtl/spk286_protected_pkg.sv', ROOT/'rtl/spk286_tss_pkg.sv']
    sources = [ROOT/'microcode/generated/spk286_microcode_pkg.sv', ROOT/'microcode/generated/spk286_microcode_rom.sv',
               *packages, *(p for p in rtl_sources if p not in packages)]
    originals = {p: p.read_bytes() for p in sources}
    (output/'source.sha256').write_text(''.join(f'{hashlib.sha256(data).hexdigest()}  {p.relative_to(ROOT).as_posix()}\n'
                                              for p,data in originals.items()), encoding='utf-8')
    from tools.string_io_vectors import records
    rows=list(records()); path=output/'data.txt'
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
        print(f'IO_MUTATION {name}: {"rejected" if reason else "passed"} status={run.returncode}')
    for bench in ('spk286_scalar_io','spk286_string_io','spk286_string_io_lifecycle'):
        execute('pristine-'+bench,bench)
    failures = []
    for name,module,bench,old,new,reason in PROBES:
        try:
            execute(name,bench,(module,old,new),reason)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            failures.append(str(error))
            print(f'IO_MUTATION {name}: INVALID {error}', flush=True)
    if any(p.read_bytes()!=data for p,data in originals.items()):
        raise RuntimeError('production source changed during mutation audit')
    if failures:
        raise RuntimeError('; '.join(failures))
    print('IO_AUDIT PASS: 19 rejected RTL mutants; 3 pristine benches; source bytes unchanged')


if __name__ == '__main__':
    main()
