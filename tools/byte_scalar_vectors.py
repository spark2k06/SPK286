# SPDX-License-Identifier: MIT
"""Independent byte scalar/EA CPU expectations, with selected word C7 controls."""
import argparse
from pathlib import Path

EDGES=(0,1,0x0f,0x10,0x7f,0x80,0xfe,0xff)

def byte(registers,index):
    return (registers[index%4] >> (8 if index>=4 else 0))%256

def put(registers,index,value,width):
    if width==16:registers[index]=value
    else:
        shift=8 if index>=4 else 0
        registers[index%4]=(registers[index%4] & ~(255<<shift)) | ((value%256)<<shift)

def arithmetic(kind,a,b,flags):
    carry=flags%2 if kind in (2,3) else 0
    if kind in (1,4,6):
        value=a|b if kind==1 else (a&b if kind==4 else a^b)
        result_flags=flags & ~0x8c5
    else:
        subtract=kind in (3,5,7)
        full=a-b-carry if subtract else a+b+carry
        signed_a=a-256 if a>=128 else a;signed_b=b-256 if b>=128 else b
        signed=signed_a-signed_b-carry if subtract else signed_a+signed_b+carry
        nibble=a%16-b%16-carry if subtract else a%16+b%16+carry
        value=full%256
        result_flags=(flags & ~0x8d5) | int(full<0 or full>255) | (int(nibble<0 or nibble>15)<<4) | (int(signed < -128 or signed > 127)<<11)
    result_flags |= (int(value.bit_count()%2==0)<<2) | (int(value==0)<<6) | (int(value>=128)<<7)
    return value,result_flags

def record(kind,form,mode=3,reg=1,rm=0,disp=0,seed=0,width=8):
    # Architectural order AX,CX,DX,BX,SP,BP,SI,DI, independent of DUT modules.
    registers=[0x8f70,0x017f,0xf080,0x2021,0x4567,0x3040,0x0110,0x0202]
    flags=(0x7cd7,0x0002,0x3013,0x4406)[seed%4] # TF/IF event scheduling has its own suites.
    immediate=EDGES[seed%8] if width==8 else (0,1,0x7fff,0x8000,0xffff)[seed%5]
    if mode==3:
        put(registers,reg,EDGES[seed%8],width)
        put(registers,rm,EDGES[(seed+5)%8],width)
    code=[];segment=3;offset=0
    # forms: rm<-reg, reg<-rm, accumulator immediate, rm immediate, register immediate.
    opcode=([0x88,0x8a,0,0xc6 if width==8 else 0xc7,0xb0+rm][form] if kind==8 else
            kind*8+(0,2,4,0)[form] if form!=3 else 0x80)
    code.append(opcode)
    memory=form in (0,1,3) and mode!=3
    if form in (0,1,3):
        encoded_reg=(0 if kind==8 else kind) if form==3 else reg
        code.append(mode*64+encoded_reg*8+rm)
        if mode==1:
            code.append(disp%256);disp=disp%256-(256 if disp%256>=128 else 0)
        elif mode==2 or mode==0 and rm==6:code.extend((disp%256,(disp//256)%256))
        else:disp=0
        if memory:
            bases=(registers[3]+registers[6],registers[3]+registers[7],registers[5]+registers[6],registers[5]+registers[7],registers[6],registers[7],registers[5],registers[3])
            offset=(disp+(0 if mode==0 and rm==6 else bases[rm]))%65536
            segment=2 if rm in (2,3) or rm==6 and mode!=0 else 3
    if form in (2,3,4):
        code.append(immediate%256)
        if width==16:code.append(immediate//256)
    initial_memory=0xa500|EDGES[(seed+3)%8]
    rm_value=(initial_memory%(1<<width)) if memory else (byte(registers,rm) if width==8 else registers[rm])
    reg_value=byte(registers,reg) if width==8 else registers[reg]
    a,b=((rm_value,reg_value) if form==0 else (reg_value,rm_value) if form==1 else
         (byte(registers,0),immediate) if form==2 else (rm_value,immediate))
    result,newflags=(b,flags) if kind==8 else arithmetic(kind,a,b,flags)
    expected=registers.copy();expected_memory=initial_memory
    blocked=memory and width==16 and offset==65535
    writing_memory=memory and form!=1 and kind!=7
    if kind!=7 and not blocked:
        if writing_memory:expected_memory=(initial_memory&0xff00)|result if width==8 else result
        else:put(expected,reg if form==1 else 0 if form==2 else rm,result,width)
    length=len(code);code.extend([0xf4]*(8-length))
    return [int(width==8),length,*code,flags,*registers,newflags if not blocked else flags,*expected,offset,segment,initial_memory,expected_memory,int(memory and (kind!=8 or form==1) and not blocked),int(writing_memory and not blocked),seed%4,int(blocked)]

def vectors():
    for kind in range(9):
        for form in (0,1):
            for reg in range(8):
                for rm in range(8):yield record(kind,form,reg=reg,rm=rm,seed=reg*8+rm)
        for form in ((2,3) if kind!=8 else (3,4)):
            for seed in range(8):
                for rm in range(8):yield record(kind,form,rm=rm,seed=seed+rm)
        for form in (0,1,3):
            for mode in range(3):
                for rm in range(8):
                    for d,disp in enumerate((0,1,0x7f,0xff80,0x7fff,0xffff)):
                        yield record(kind,form,mode=mode,reg=(rm+d)%8,rm=rm,disp=disp,seed=d+rm+kind)
    # Boundary byte FFFF is legal; the matched word store faults without a bus write.
    for width in (8,16):
        for offset in (0,1,0xfffe,0xffff):
            for seed in range(8):yield record(8,3,mode=0,rm=6,disp=offset,seed=seed,width=width)

def write_vectors(path):
    path.parent.mkdir(parents=True,exist_ok=True)
    records=list(vectors())
    with path.open('w',encoding='ascii',newline='\n') as f:
        f.write(f'{len(records):x}\n')
        for row in records:f.write(' '.join(f'{v:x}' for v in row)+'\n')
    return len(records)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();print(f'BYTE_SCALAR_VECTORS PASS: {write_vectors(args.output)} independent cases')
