#!/usr/bin/env python3
"""Prove exact next-PC prediction and one-edge ROM alignment from actual RTL."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess

REFERENCE = 'c554585'


def compact(text):
    return re.sub(r'\s+', '', re.sub(r'//[^\n]*|/\*.*?\*/', '', text, flags=re.S))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    out = parser.parse_args().output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[1]
    paths = ('rtl/spk286.sv', 'rtl/spk286_microsequencer.sv',
             'microcode/generated/spk286_microcode_pkg.sv',
             'microcode/generated/spk286_microcode_rom.sv',
             'microcode/generated/spk286_microcode_sync_rom.sv')
    top, sequencer, package, rom, sync_rom = [(root/p).read_text() for p in paths]
    old_top, old_seq, old_package, old_rom = [subprocess.check_output(
        ['git', 'show', REFERENCE+':'+p], cwd=root, text=True) for p in paths[:4]]
    predictor = re.search(r'    // The synchronous ROM samples.*?\n    end\n', sequencer, re.S).group(0)
    restored = sequencer.replace(predictor, '').replace(
        '    output logic [ADDRESS_WIDTH-1:0] next_micro_pc,\n', '')
    assert compact(restored) == compact(old_seq), 'Sequencer state/output RTL changed'
    integration = re.search(r'`ifdef SPK286_P07_SYNC_MICROCODE\n.*?\n`endif', top, re.S).group(0)
    binding = '''`ifdef SPK286_P07_SYNC_MICROCODE
        .next_micro_pc(next_micro_pc),
`else
        .next_micro_pc(unused_next_micro_pc),
`endif'''
    baseline_rom = '''    spk286_microcode_rom microcode_rom (
        .address(micro_pc), .word(micro_word), .valid(micro_valid)
    );'''
    assert compact(top.replace(integration, baseline_rom).replace(binding, '')) == compact(old_top), 'Unrelated CPU RTL changed'
    assert compact(package) == compact(old_package), 'Microcode constants/branches changed'
    assert compact(rom) == compact(old_rom), 'Baseline ROM content/template changed'
    (out/'reference_microsequencer.sv').write_text(old_seq.replace('module spk286_microsequencer', 'module reference_microsequencer'))

    def run(source, label, sat, success):
        source_path = out/(label+'.sv')
        source_path.write_text(source)
        command = f'read_verilog -sv {source_path}; prep -top miter; flatten; memory_map; opt; sat {sat}'
        result = subprocess.run(['yosys', '-p', command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (out/(label+'.log.gz')).write_bytes(gzip.compress(result.stdout, mtime=0))
        assert result.returncode == 0 and success.encode() in result.stdout, label+' failed; see compressed log'

    # Convert only sequential assignment LHS to next-state variables. RHS
    # remains the original pre-edge input state, preserving NBA semantics.
    body = old_seq[old_seq.index('    always_ff @(posedge clk) begin'):old_seq.rindex('\nendmodule')]
    body = body.replace('always_ff @(posedge clk)', 'always_comb')
    state = ('active', 'micro_pc', 'micro_entry', 'retired', 'fault')
    for name in state:
        body = re.sub(r'\b'+name+r'\s*<=', 'expected_'+name+' =', body)
    body = body.replace('always_comb begin', 'always_comb begin\n'+''.join(
        '        expected_'+name+' = '+name+';\n' for name in state), 1)
    common = '''module miter(
input reset, cancel, enable, start, rom_valid, rom_end,
input operation_done, operation_retire, branch_request, branch_target_valid,
input active, retired, fault,
input [ADDRESS_WIDTH-1:0] micro_pc, micro_entry, start_entry, branch_target,
output mismatch
);
localparam [ADDRESS_WIDTH:0] DEPTH=(ADDRESS_WIDTH+1)'(ROM_DEPTH);
wire start_ready=enable && !reset && !cancel && !active && !fault;
reg expected_active, expected_retired, expected_fault;
reg [ADDRESS_WIDTH-1:0] expected_micro_pc, expected_micro_entry, next_micro_pc;
'''+body+'\n'+predictor+'\nassign mismatch=expected_micro_pc != next_micro_pc;\nendmodule\n'
    real_depth = int(re.search(r'localparam integer MC_DEPTH = ([0-9]+);', package).group(1))
    dimensions = ((10, real_depth), (10, 1024), (4, 10))
    for width, depth in dimensions:
        proof = common.replace('module miter(', f'module miter #(parameter ADDRESS_WIDTH={width}, ROM_DEPTH={depth}) (')
        run(proof, f'pc-{width}-{depth}', '-verify -prove mismatch 0 -show-inputs', 'SUCCESS!')
        if width == 10 and depth == real_depth:
            negative = proof.replace('if (reset || cancel)\n            next_micro_pc', 'if (reset)\n            next_micro_pc')
            assert negative != proof
            run(negative, 'cancel-negative', '-prove mismatch 0 -show-inputs', 'FAIL!')

    # Flatten the actual package constants for the Yosys Verilog frontend;
    # no memory content is rebuilt by the checker.
    names = dict(re.findall(r'localparam (?:integer|logic \[[^\]]+\]) (MC_[A-Z0-9_]+) = ([^;]+);', package))
    assert names['MC_ADDR_WIDTH'] == '10' and names['MC_WORD_WIDTH'] == '8'
    def flatten_package(source):
        for name, value in sorted(names.items(), key=lambda item: -len(item[0])):
            source = source.replace('spk286_microcode_pkg::'+name, '('+value+')')
        return source
    actual = flatten_package(sync_rom)
    model = flatten_package(old_rom).replace('module spk286_microcode_rom', 'module reference_rom')
    # The candidate async module is not used in this proof; the reference is
    # the committed previous ROM. Skip unconstrained pre-clock output state.
    rom_miter = '''
module miter(input clk, input [9:0] address, output mismatch);
wire [7:0] old_word, new_word;
wire old_valid, new_valid;
reg [8:0] expected;
reference_rom old_rom(.address(address),.word(old_word),.valid(old_valid));
spk286_microcode_sync_rom new_rom(.clk(clk),.address(address),.word(new_word),.valid(new_valid));
always @(posedge clk) expected <= {old_valid, old_word};
assign mismatch=expected != {new_valid, new_word};
endmodule
'''
    sat = '-seq 2 -prove-skip 1 -prove mismatch 0 -show-inputs'
    run(model+'\n'+actual+rom_miter, 'rom-edge', '-verify '+sat, 'SUCCESS!')
    negative = re.sub(r"contents\[10'd0\] = \{1'b1, \(8'd[0-9]+\)\};",
                      "contents[10'd0] = {1'b1, (8'd0)};", actual)
    assert negative != actual
    run(model+'\n'+negative+rom_miter, 'word-negative', sat, 'FAIL!')
    (out/'receipt.json').write_text(json.dumps({
        'status':'EXACT_NEXT_PC_AND_ONE_EDGE_ROM_EQUIVALENCE_PASS',
        'reference':REFERENCE,
        'sequencer_dimensions':dimensions,
        'scope':'all two-state sequencer states/controls and priorities at real/generic depths; all ROM addresses/content; actual initialized read template; arbitrary pre-clock outputs skipped once; no sequential/control/branch/content changes elsewhere',
        'negative_controls':['CANCEL_OMISSION_REJECTED','FIRST_ROM_WORD_MUTANT_REJECTED'],
        'source_sha256':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths},
        'evidence_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()}
    },indent=2)+'\n')
    print('SYNC_MICROCODE_FORMAL_PASS; both negative controls rejected')


if __name__ == '__main__':
    main()
