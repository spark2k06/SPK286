# SPDX-License-Identifier: MIT
"""Integer oracle with a separately evidenced finite byte-IDIV overflow rule."""
import argparse
from pathlib import Path
import random


def signed(value,width):
    value%=1<<width
    return value-(1<<width) if value>=1<<(width-1) else value


def status(value,width):
    value%=1<<width
    return 128*int(value>=1<<(width-1))+64*int(value==0)+4*int((value%256).bit_count()%2==0)


def byte_overflow_candidate(dividend,source):
    # Only negative signed-byte mathematical overflow reaches this function.
    # Work with an integer bit string, independently of the RTL's captured
    # register reuse and parallel mathematical divider.
    negative=dividend<0
    bits=(~dividend if negative else dividend)%65536
    divisor=abs(source)
    for _ in range(8):
        bits=bits*2%65536
        if bits//256>=divisor:bits=bits-divisor*256+1
    quotient=bits%256;remainder=bits//256+int(negative)
    remainder%=256
    if remainder==divisor:remainder=0;quotient=(quotient+1)%256
    return ((-remainder if negative else remainder)%256)*256+(-quotient)%256


def evaluate(kind,narrow,dividend,source):
    width=8 if narrow else 16;size=1<<width;source%=size
    if kind<2:
        left=dividend%size
        product=signed(left,width)*signed(source,width) if kind==1 else left*source
        overflow=product!=signed(product,width) if kind==1 else product>=size
        flags=status(product//size,width)+(0x801 if overflow else 0)
        return product%65536,(product//65536)%65536 if width==16 else 0,flags,0x8c5,1,0
    numerator=dividend%(size*size)
    if kind==3:numerator=signed(numerator,2*width);source=signed(source,width)
    if source==0:return 0,0,0,0,0,1
    magnitude=abs(numerator)//abs(source)
    quotient=-magnitude if (numerator<0)!=(source<0) else magnitude
    remainder=numerator-quotient*source
    if not (-(size//2) if kind==3 else 0)<=quotient<=(size//2-1 if kind==3 else size-1):
        if kind==3 and narrow and quotient < -128:
            candidate=byte_overflow_candidate(numerator,source)
            if candidate%256==128:return candidate,0,0,0,1,0
        return 0,0,0,0,0,1
    return ((remainder%256)*256+quotient%256 if narrow else quotient%65536), (0 if narrow else remainder%65536),0,0,1,0


def vectors():
    for kind in (0,1):
        for left in range(256):
            for right in range(256):
                args=kind,1,0xa53c0000+left+((left*13+right)%256)*256,right
                yield (*args,*evaluate(*args))
    for kind in (2,3):
        for dividend in range(65536):
            args=kind,1,0xc5310000+dividend,((dividend>>8)^(dividend*37))%256
            yield (*args,*evaluate(*args))
    rng=random.Random(0x2867014)
    edges=(0,1,2,0x7f,0x80,0xff,0x100,0x7fff,0x8000,0xfffe,0xffff)
    for kind in range(4):
        for high in edges:
            for low in edges:
                for source in edges:
                    args=kind,0,high*65536+low,source
                    yield (*args,*evaluate(*args))
        for _ in range(4096):
            args=kind,0,rng.randrange(1<<32),rng.randrange(65536)
            yield (*args,*evaluate(*args))
    for kind in (2,3):
        for narrow in (0,1):
            width=8 if narrow else 16;size=1<<width
            for source in (1,2,size//2-1,size//2,size-2,size-1):
                divisor=signed(source,width) if kind==3 else source
                for quotient in (-size//2-1,-size//2,-1,0,1,size//2-1,size//2,size-1,size):
                    for remainder in (-1,0,1):
                        args=kind,narrow,(divisor*quotient+remainder)%(size*size),source
                        yield (*args,*evaluate(*args))


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    rows=list(vectors());args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'MULDIV_VECTORS PASS: {len(rows)} independent products, quotients and fault boundaries')


if __name__=='__main__':main()
