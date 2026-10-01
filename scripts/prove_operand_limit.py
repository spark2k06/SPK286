#!/usr/bin/env python3
"""Prove the actual operand limit predicate for all widths/ranges/offsets."""
import argparse,hashlib,json,re,subprocess
from pathlib import Path
REFERENCE='7797942'
def assignment(s):return re.search(r'    assign within_limit\s*=.*?;',s,re.S).group(0)
def compact(s):return re.sub(r'\s+','',re.sub(r'//[^\n]*|/\*.*?\*/','',s,flags=re.S))
ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('output',type=Path)
out=ap.parse_args().output.resolve();out.mkdir(parents=True,exist_ok=False)
root=Path(__file__).resolve().parents[1];p=root/'rtl/spk286_operand.sv'
cur=p.read_text();old=subprocess.check_output(['git','show',REFERENCE+':rtl/spk286_operand.sv'],cwd=root,text=True)
assert compact(cur.replace(assignment(cur),assignment(old)))==compact(old),'Unrelated operand or sequential change'
text='module miter(input [15:0] offset,segment_limit,input request_byte,segment_expand_down,output mismatch);\nwire within_limit, old_limit;\n'+assignment(old).replace('within_limit','old_limit')+'\n'+assignment(cur)+'\nassign mismatch=within_limit!=old_limit;\nendmodule\n'
def run(s,stem,verify):
 q=out/(stem+'.sv');q.write_text(s)
 cmd=f'read_verilog -sv {q}; prep -top miter; flatten; opt; sat '+('-verify ' if verify else '')+'-prove mismatch 0 -show-inputs'
 r=subprocess.run(['yosys','-p',cmd],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (out/(stem+'.log')).write_text(r.stdout);return r
r=run(text,'proof',True);assert r.returncode==0 and 'SUCCESS!' in r.stdout
bad=text.replace(assignment(cur),assignment(cur).replace('offset != 16\'hFFFF','1\'b1'))
assert bad!=text
r=run(bad,'negative',False);assert r.returncode==0 and 'FAIL!' in r.stdout
(out/'receipt.json').write_text(json.dumps({'status':'EXACT_OPERAND_LIMIT_EQUIVALENCE_PASS','reference':REFERENCE,'scope':'all 2^34 two-state offset/limit/width/expand-down combinations; actual RTL; no changes to sequential state or any other operand expression','negative_control':'REJECTED','source_sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'evidence_sha256':{q.name:hashlib.sha256(q.read_bytes()).hexdigest() for q in out.iterdir() if q.is_file()}},indent=2)+'\n')
print('OPERAND_LIMIT_FORMAL_PASS; word-at-FFFF mutant rejected')
