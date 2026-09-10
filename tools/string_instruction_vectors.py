"""Independent byte-addressed string oracle with explicit physical fault effects."""
import argparse
from pathlib import Path
from tools.far_instruction_vectors import FarCase
from tools.stack_frame_vectors import SEGMENTS,WordFault

class StringCase(FarCase):
    def __init__(self,opcode,repeat,override,df,si,di,cx,seed):
        prefix=[] if override is None else [0x26+override*8]
        if repeat:prefix.insert(0,0xf2 if repeat==1 else 0xf3)
        if seed%7==0:prefix.insert(0,0xf0)
        super().__init__([*prefix,opcode],0x6800,seed)
        self.initial[1]=cx;self.initial[6]=si;self.initial[7]=di;self.expected=self.initial.copy()
        self.flags=(self.flags&~0x400)|(df*0x400);self.final_flags=self.flags
        self.width=1+(opcode&1);self.opcode=opcode;self.repeat=repeat;self.override=override;self.df=df

    def initialize(self,address,value):
        self.ensure(address)
        for b in range(self.width):self.before[address+b]=self.memory[address+b]=(value>>(8*b))&255

    def access(self,index,segment,value=None):
        offset=self.expected[index];delta=-self.width if self.df else self.width
        self.expected[index]=(offset+delta)&65535
        if self.width==2 and offset==65535:raise WordFault
        address=(SEGMENTS[segment]<<4)+offset
        if self.width==2:return self.transfer(address,value)
        self.ensure(address);write=value is not None
        if write:self.memory[address]=value&255
        else:value=self.memory[address]
        self.transactions.append((int(write),address,0 if address&1 else 1,(value&255)<<(8 if address&1 else 0)))
        return value&255

    def decrement(self):
        if self.repeat:self.expected[1]=(self.expected[1]-1)&65535

    def subtract(self,left,right):
        bits=8*self.width;mask=(1<<bits)-1;sign=1<<(bits-1);left&=mask;right&=mask;value=(left-right)&mask
        flags=int(left<right)|(int((value&255).bit_count()%2==0)<<2)|((left^right^value)&16)|(int(value==0)<<6)|(int(bool(value&sign))<<7)|(int(bool((left^right)&(left^value)&sign))<<11)
        self.final_flags=(self.final_flags&~0x8d5)|flags

    def calculate(self):
        family=self.opcode&0xfe;source=3 if self.override is None else self.override
        count=self.initial[1] if self.repeat else 1
        for _ in range(count):
            try:
                if family==0xa6:
                    right=self.access(7,0);self.decrement();left=self.access(6,source);self.subtract(left,right)
                elif family==0xae:
                    self.decrement();right=self.access(7,0);self.subtract(self.expected[0],right)
                elif family==0xac:
                    self.decrement();value=self.access(6,source)
                    self.expected[0]=value if self.width==2 else (self.expected[0]&0xff00)|value
                else:
                    self.decrement()
                    value=self.access(6,source) if family==0xa4 else self.expected[0]
                    try:self.access(7,0,value)
                    except WordFault:
                        self.decrement();raise
            except WordFault:self.fault=13;break
            if self.repeat and family in (0xa6,0xae) and bool(self.final_flags&64)!=(self.repeat==2):break
        return self

    def row(self):
        data=super().row();return data[:31]+[self.final_flags]+data[31:]


def make_case(opcode,repeat,override,df,si,di,cx,seed):
    c=StringCase(opcode,repeat,override,df,si,di,cx,seed);count=cx if repeat else 1
    source=3 if override is None else override;delta=-c.width if df else c.width;family=opcode&0xfe
    for step in range(count):
        src=(SEGMENTS[source]<<4)+((si+step*delta)&65535);dst=(SEGMENTS[0]<<4)+((di+step*delta)&65535)
        value=(0x317b+step*0x1367+seed*0x439)&((1<<(8*c.width))-1)
        if family in (0xa4,0xa6,0xac):c.initialize(src,value)
        if family in (0xa6,0xae):
            left=value if family==0xa6 else c.initial[0]
            equal=(step<seed%4) if repeat==2 else (step>=seed%4)
            c.initialize(dst,left if equal else left^1)
        else:c.ensure(dst)
    return c.calculate()


def records():
    seed=0
    for opcode in (0xa4,0xa5,0xa6,0xa7,0xaa,0xab,0xac,0xad,0xae,0xaf):
        for repeat in (0,1,2):
            for override in (None,0,1,2,3):
                for df in (0,1):
                    for si,di in ((0,0),(1,2),(0xfffe,0xfffe),(0xffff,0xffff),(1,0xffff),(0xffff,1),(0xfffc,0xfffe),(0xfffe,0xfffc)):
                        for cx in (0,1,2,7):
                            yield make_case(opcode,repeat,override,df,si,di,cx,seed).row();seed+=1
    for opcode in (0xa4,0xa5,0xa6,0xa7):
        for repeat in (0,1,2):
            for df in (0,1):
                for shift in (-3,-2,-1,0,1,2,3):
                    for cx in (1,2,9,16):
                        yield make_case(opcode,repeat,0,df,0x3401,0x3401+shift,cx,seed).row();seed+=1


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);a=p.parse_args();rows=list(records());a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows));print(f'STRING_INSTRUCTION_VECTORS PASS: {len(rows)} independent cases')

if __name__=='__main__':main()
