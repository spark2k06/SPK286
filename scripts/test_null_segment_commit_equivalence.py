"""Source-extracted null-segment commit equivalence and gate comparison.

No production source is edited. The candidate changes one assignment, retaining
the complete selector service and all its public outputs. Every qualifier in
the target's actual combinational dependency graph is included; retained state,
operation and the common permission are independent symbolic inputs.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RAW = TIMED = SELECTOR = PACKAGE = None
TARGET = 'descriptor_segment_null_commit'
OLD = """    assign descriptor_segment_null_commit = descriptor_begin && segment_reload_operation &&
                                           descriptor_selector_null && !descriptor_pre_fault && segment_index != 2'd2;"""
NEW = """    assign descriptor_segment_null_commit = !descriptor_active_q && segment_reload_operation &&
                                           tmp0_q[15:2] == 14'd0 && segment_index != 2'd2;"""
SELECTOR_OUTPUTS = {
    'descriptor_unused_index': '[12:0]', 'descriptor_selector_ti': '',
    'descriptor_unused_rpl': '[1:0]', 'descriptor_selector_null': '',
    'descriptor_unused_end': '[20:0]', 'descriptor_selector_limit_valid': '',
    'descriptor_unused_selector_valid': '', 'descriptor_selector_address': '[23:0]',
    'descriptor_selector_carry': '',
}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def assignments(source):
    return {m[1]: m[0] for m in re.finditer(
        r'^    assign (\w+)\s*=\s*(.*?);', source, re.M | re.S)}

def types(source):
    result = {}
    for width, names in re.findall(
        r'\b(?:logic|wire)\s*(\[[^]\n]+\])?\s*'
        r'([A-Za-z_]\w*(?:[ \t]*,[ \t]*[A-Za-z_]\w*)*)', source):
        for name in re.split(r'\s*,\s*', names):
            assert name not in result or result[name] == width, name
            result[name] = width.replace('spk286_microcode_pkg::', '').replace('MC_WORD_WIDTH', '8')
    return result

def dependencies(statement):
    expression = statement.split('=', 1)[1]
    expression = re.sub(r"\d*'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+", '', expression)
    return set(re.findall(r'\b[A-Za-z_]\w*\b', expression)) - {'spk286_microcode_pkg'}

def run(out, label, commands, *, reject=False):
    script = out / (label+'.ys')
    script.write_text(commands+'\n', newline='\n')
    result = subprocess.run(['yosys', '-Q', '-s', str(script)], cwd=ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    log = result.stdout.decode()
    (out/(label+'.log')).write_bytes(result.stdout)
    if reject:
        assert result.returncode != 0 and 'proof did fail' in log and 'time out' not in log
    else:
        assert result.returncode == 0, (label, log[-1000:])
    return log

def build_cone(source, suffix, constants):
    graph = assignments(source)
    assert graph[TARGET] == OLD
    widths = types(source)
    todo = [TARGET]; visited = set(); nodes = set(); inputs = set()
    while todo:
        name = todo.pop()
        if name in visited or name in constants:
            continue
        visited.add(name)
        if name in ('allowed', 'implementation_allowed'):
            inputs.add(name)
        elif name in SELECTOR_OUTPUTS:
            todo.extend(('descriptor_selector_value', 'descriptor_table_limit', 'descriptor_table_base'))
        elif name in graph:
            nodes.add(name)
            todo.extend(dependencies(graph[name]))
        else:
            assert name in widths, ('undeclared input', name)
            inputs.add(name)
    assert TARGET in nodes and 'descriptor_pre_fault' in nodes
    selector_instances = re.findall(
        r'    spk286_selector descriptor_selector \(.*?\n    \);', source, re.S)
    assert len(selector_instances) == 1
    instance = selector_instances[0]
    for name in SELECTOR_OUTPUTS:
        assert re.search(r'\(\s*'+re.escape(name)+r'\s*\)', instance), name
    outputs = {TARGET: '', **SELECTOR_OUTPUTS}
    constant_lines = '\n'.join(constants.values())
    ports = ',\n'.join('input wire '+widths[name]+' '+name for name in sorted(inputs))
    ports += ',\n'+',\n'.join('output wire '+width+' '+name for name,width in outputs.items())
    declarations = '\n'.join('wire '+widths[name]+' '+name+';' for name in sorted(nodes-outputs.keys()))
    body = '\n'.join(graph[name] for name in sorted(nodes))
    module = ('module cone_'+suffix+'(\n'+ports+'\n);\n'+constant_lines+'\n'
              + declarations+'\n'+body+'\n'+instance+'\nendmodule\n')
    return module.replace('spk286_microcode_pkg::', ''), inputs, outputs, sorted(nodes)

def mapped_depth(module, input_name=None):
    cells = module['cells']; drivers = {}
    for cell in cells.values():
        for port, direction in cell['port_directions'].items():
            if direction == 'output':
                for bit in cell['connections'][port]: drivers[bit] = cell
    inputs = {b for p in module['ports'].values() if p['direction']=='input' for b in p['bits']}
    sources = inputs if input_name is None else set(module['ports'][input_name]['bits'])
    memo = {}
    def depth(bit):
        if isinstance(bit,str): return -100000
        if bit in inputs: return 0 if bit in sources else -100000
        if bit not in memo:
            cell=drivers[bit]
            memo[bit]=1+max(depth(b) for p,d in cell['port_directions'].items()
                           if d=='input' for b in cell['connections'][p])
        return memo[bit]
    return max(0,max(depth(bit) for bit in module['ports'][TARGET]['bits']))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--cpu-root',type=Path,
        help='Standalone SPK286 tree; default is this repo or its vendor/spk286 tree')
    parser.add_argument('--timed',type=Path,
        help='Optional installed/generated PCAT timed executor; required explicitly in PCAT')
    args=parser.parse_args()
    embedded=(ROOT/'vendor/spk286/rtl/spk286_micro_executor.sv').is_file()
    if embedded and args.timed is None:
        parser.error('PCAT validation requires --timed pointing to its actual timed executor')
    cpu_root=(args.cpu_root or (ROOT/'vendor/spk286' if embedded else ROOT)).resolve()
    global RAW,TIMED,SELECTOR,PACKAGE
    RAW=cpu_root/'rtl/spk286_micro_executor.sv'
    SELECTOR=cpu_root/'rtl/spk286_selector.sv'
    PACKAGE=cpu_root/'microcode/generated/spk286_microcode_pkg.sv'
    TIMED=args.timed.resolve() if args.timed is not None else None
    out=args.output.resolve()
    assert out.is_relative_to((ROOT/'build').resolve())
    out.mkdir(parents=True,exist_ok=False)
    sources=[RAW,SELECTOR,PACKAGE,Path(__file__).resolve()]+([TIMED] if TIMED is not None else [])
    def source_name(path):
        return path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else path.as_posix()
    before={source_name(p):sha(p) for p in sources}
    constants={m[1]:m[0] for m in re.finditer(r'^    localparam .*?\b(MC_\w+)\s*=.*?;',PACKAGE.read_text(),re.M)}
    assert 'MC_WORD_WIDTH' in constants and "8'd77" in constants['MC_WRITE_SEG16_TMP0']
    assert constants['MC_WORD_WIDTH'].strip() == 'localparam integer MC_WORD_WIDTH = 8;'
    selector=SELECTOR.read_text()
    (out/'selector.sv').write_text(selector,newline='\n')
    results={}
    for flavor,path in [('raw',RAW)]+([('timed',TIMED)] if TIMED is not None else []):
        installed=path.read_text()
        module='spk286_micro_executor' if flavor=='raw' else 'spk286_profiled_micro_executor'
        assert len(re.findall(r'\bmodule\s+'+module+r'\s*#\(',installed))==1, 'Unexpected executor module anchor'
        if installed.count(OLD)==1 and installed.count(NEW)==0:
            source=installed; applied=False
        else:
            assert installed.count(NEW)==1 and installed.count(OLD)==0
            source=installed.replace(NEW,OLD,1); applied=True
            assert source.replace(OLD,NEW,1)==installed
        old,inputs,outputs,nodes=build_cone(source,'reference',constants)
        candidate=old.replace('module cone_reference(', 'module cone_candidate(',1).replace(OLD,NEW,1)
        assert candidate!=old and candidate.count(NEW)==1
        # Reverse exactly the single assignment and module-name change.
        assert candidate.replace(NEW,OLD,1).replace('module cone_candidate(', 'module cone_reference(',1)==old
        declarations='\n'.join('wire '+width+' '+side+'_'+name+';' for side in ('old','new') for name,width in outputs.items())
        widths=types(source)
        ports=',\n'.join('input wire '+widths[name]+' '+name for name in sorted(inputs))
        instances='\n'.join('cone_'+kind+' '+side+'_instance('+','.join(
            ['.'+name+'('+name+')' for name in sorted(inputs)] +
            ['.'+name+'('+side+'_'+name+')' for name in outputs])+');'
            for side,kind in (('old','reference'),('new','candidate')))
        checks='\n'.join('assert(old_'+name+' == new_'+name+');' for name in outputs)
        wrapper='module miter(\n'+ports+'\n);\n'+declarations+'\n'+instances+'\nalways @* begin\n'+checks+'\nend\nendmodule\n'
        cases=[('actual',candidate,False),
               ('missing-ss-null-guard',candidate.replace(" && segment_index != 2'd2",'',1),True),
               ('wrong-null-selector-slice',candidate.replace("tmp0_q[15:2] == 14'd0","tmp0_q[15:3] == 13'd0",1),True),
               ('broken-operation-qualifier',candidate.replace('!descriptor_active_q && segment_reload_operation &&\n                                           tmp0_q','!descriptor_active_q &&\n                                           tmp0_q',1),True),
               ('missing-descriptor-active-guard',candidate.replace('!descriptor_active_q && segment_reload_operation','segment_reload_operation',1),True)]
        for label,body,reject in cases:
            rtl=out/(flavor+'-'+label+'.sv')
            rtl.write_text(selector+'\n'+old+'\n'+body+'\n'+wrapper,newline='\n')
            log=run(out,flavor+'-'+label,f'read_verilog -formal -sv {rtl}\nprep -top miter -flatten\nopt\nsat -verify -prove-asserts -show-inputs -timeout 60',reject=reject)
            if not reject: assert 'SUCCESS' in log
        synthesis={}
        for label,body in (('reference',old),('candidate',candidate)):
            rtl=out/(flavor+'-'+label+'-cone.sv');rtl.write_text(selector+'\n'+body,newline='\n')
            mapped=out/(flavor+'-'+label+'-mapped.json')
            run(out,flavor+'-'+label+'-synth',f'read_verilog -sv {rtl}\nsynth -top cone_{label} -flatten\nstat\nwrite_json {mapped}')
            netlist=json.loads(mapped.read_text())['modules']['cone_'+label]
            permission='implementation_allowed' if flavor=='timed' else 'allowed'
            synthesis[label]={'gates':len(netlist['cells']),'target_depth':mapped_depth(netlist),'target_depth_from_permission':mapped_depth(netlist,permission)}
        results[flavor]={'candidate_installed':applied,'reconstructed_reference_sha256':hashlib.sha256(source.encode()).hexdigest(),
                        'nodes':nodes,'arbitrary_inputs':sorted(inputs),'asserted_outputs':list(outputs),'generic_mapping':synthesis,'negative_controls':[name for name,_,reject in cases if reject]}
        candidate_source=source.replace(OLD,NEW,1)
        assert candidate_source.replace(NEW,OLD,1)==source
        (out/(path.name+'.candidate')).write_text(candidate_source,newline='\n')
    assert {source_name(p):sha(p) for p in sources}==before
    receipt={'status':'NULL_SEGMENT_COMMIT_SPECIALIZATION_EQUIVALENCE_PASS',
             'scope':'Actual selected qualifier and selector dependency cones, 10 observable outputs, all input bit patterns, no assumptions or reachable-state restrictions; no new state/cycles',
             'cpu_root':str(cpu_root),'embedded_project':embedded,'timed_required':embedded,
             'selected_variants':list(results),
             'sources_sha256':before,'original_assignment':OLD,'replacement_assignment':NEW,
             'results':results,'generic_mapping_scope':'Yosys synth/ABC gates and unit gate depths; not Cyclone V placed timing/resource prediction',
             'artifacts_sha256':{p.name:sha(p) for p in out.iterdir() if p.is_file()}}
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',newline='\n')
    print(receipt['status']);print(json.dumps({key:value['generic_mapping'] for key,value in results.items()}))

if __name__=='__main__': main()
