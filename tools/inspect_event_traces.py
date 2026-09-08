"""Extract actual VCD bus/context evidence from the pristine event replays."""
import argparse
import hashlib
import json
from pathlib import Path


SIGNALS=('clk','reset','ready','bus_valid','bus_status','bus_write','bus_bhe_n','bus_lock','hlda',
         'address','data_in','data_out','data_oe','instruction_retired','event_completed','debug_event_vector',
         'debug_event_kind','debug_cs','debug_cs_base','debug_ip','debug_flags','debug_gpr')


def inspect(path):
    variables={};scope=[];state={};previous=None;timestamp=0;ids=None
    transfers=[];events=[];retires=[];grants=[]
    def sample():
        nonlocal previous
        if ids is None:return
        current={name:state.get(symbol) for name,symbol in ids.items()}
        if previous is not None and previous['clk']==0 and current['clk']==1 and not previous['reset']:
            if current['hlda'] and not previous['hlda']:
                if current['bus_valid']:raise ValueError(f'{path}: bus active during HLDA grant')
                grants.append(timestamp)
            if previous['bus_valid'] and previous['ready']:
                transfers.append({'time':timestamp,**{name:previous[name] for name in
                    ('bus_status','bus_write','bus_bhe_n','bus_lock','address','data_in','data_out','data_oe')}})
            context={name:current[name] for name in ('debug_cs','debug_cs_base','debug_ip','debug_flags')}
            context['sp']=(current['debug_gpr'] >> 64) & 65535
            if current['event_completed']:
                events.append({'time':timestamp,'kind':current['debug_event_kind'],'vector':current['debug_event_vector'],**context})
            if current['instruction_retired']:retires.append({'time':timestamp,**context})
            if current['event_completed'] or current['instruction_retired']:
                if context['debug_cs_base'] != context['debug_cs']*16:
                    raise ValueError(f'{path}: incoherent completed CS cache')
        previous=current
    with path.open() as source:
        for raw in source:
            line=raw.strip()
            if line.startswith('$scope'):scope.append(line.split()[2])
            elif line.startswith('$upscope'):scope.pop()
            elif line.startswith('$var'):
                fields=line.split();variables['.'.join(scope+[fields[4]])]=fields[3]
            elif line.startswith('$enddefinitions'):
                prefix=min((name.rsplit('.',1)[0] for name in variables if name.endswith('.debug_event_vector')),key=lambda p:len(p.split('.')))
                ids={name:variables[prefix+'.'+name] for name in SIGNALS}
            elif line.startswith('#'):
                sample();timestamp=int(line[1:])
            elif line and line[0] in '01xz' and not line.startswith('$'):
                state[line[1:]]=int(line[0]) if line[0] in '01' else None
            elif line.startswith('b'):
                bits,symbol=line[1:].split()
                state[symbol]=int(bits,2) if not any(bit in bits for bit in 'xz') else None
    sample()
    if ids is None or not transfers:raise ValueError(f'{path}: missing trace evidence')
    return {'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
            'bus_transfers':transfers,'events':events,'retirements':retires,'hold_grants':grants}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--intr-trace',type=Path,required=True)
    args=parser.parse_args()
    result={}
    for name in ['pristine-event-'+opcode for opcode in ('9C','9D','CC','CD','CE','CF','F4','FA','FB')]+['pristine-fault-6','pristine-fault-13']:
        row=inspect(args.directory/(name+'.vcd'))
        if name.startswith('pristine-fault'):
            if len(row['events'])!=1 or row['retirements'] or row['events'][0]['kind']!=1:
                raise ValueError(f'{name}: fault completion/retirement trace mismatch')
        elif len(row['retirements'])!=1:
            raise ValueError(f'{name}: expected one instruction retirement')
        if any(t['bus_status']==0 for t in row['bus_transfers']):
            raise ValueError(f'{name}: software/exception replay unexpectedly issued INTA')
        result[name]=row
    row=inspect(args.intr_trace)
    acknowledgements=[t for t in row['bus_transfers'] if t['bus_status']==0]
    writes=[t for t in row['bus_transfers'] if t['bus_status']==6]
    if (len(acknowledgements)!=2 or any(t['data_oe'] or not t['bus_lock'] for t in acknowledgements)
        or [t['data_in'] & 255 for t in acknowledgements]!=[0x99,0x42]
        or len(row['events'])!=1 or row['events'][0]['vector']!=0x42 or row['events'][0]['kind']!=4
        or row['retirements'] or not row['hold_grants'] or len(writes)<2
        or not all(t['bus_lock'] for t in writes[:2])):
        raise ValueError('INTR trace: acknowledgement/vector/LOCK/odd-word/HOLD history mismatch')
    result['intr-lifecycle']=row
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print('EVENT_TRACE PASS: 11 pristine VCDs plus physical INTA/LOCK/HOLD history; coherent completed CS caches')


if __name__=='__main__':main()
