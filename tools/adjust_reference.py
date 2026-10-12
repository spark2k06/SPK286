# SPDX-License-Identifier: MIT
"""Independent closed-form decimal and radix expectations; no RTL recurrence."""
import argparse
from pathlib import Path


def status(value):
    value %= 256
    return 4*int(value.bit_count()%2==0)+64*int(value==0)+128*int(value>=128)


def evaluate(kind, operand, radix, carry, auxiliary):
    high, low = divmod(operand,256)
    adjust = low%16>9 or auxiliary
    if kind in (0,1):
        high_adjust = low>153 or carry
        result = (low+(6*adjust+96*high_adjust)*(1 if kind==0 else -1))%256
        carry_out = high_adjust or (kind==1 and adjust and low<6)
        return high*256+result, status(result)+16*adjust+carry_out, 0xd5, 1, 0
    if kind in (2,3):
        result = (operand+(262 if kind==2 else -262)*adjust)%65536
        result = result//256*256+result%16
        return result, 17*adjust, 0x11, 1, 0
    if kind==4:
        if not radix: return operand,status(low//2),0x8d5,0,1
        quotient,remainder=divmod(low,radix)
        return quotient*256+remainder,status(remainder),0xc4,1,0
    if kind==5:
        result=(low+high*radix)%256
        return result,status(result),0xc4,1,0
    return operand,0,0,0,1


def vectors():
    for kind in range(4):
        for high in (0,1,0x7f,0x80,0xfe,0xff):
            for low in range(256):
                for carry in (0,1):
                    for auxiliary in (0,1):
                        args=(kind,high*256+low,0,carry,auxiliary)
                        yield (*args,*evaluate(*args))
    for radix in range(256):
        for low in range(256):
            args=(4,((low*13+radix*17)%256)*256+low,radix,low%2,radix%2)
            yield (*args,*evaluate(*args))
        for high in range(256):
            for low in (0,1,0x80,0xff):
                args=(5,high*256+low,radix,high%2,low%2)
                yield (*args,*evaluate(*args))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();rows=list(vectors());args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'ADJUST_VECTORS PASS: {len(rows)} independent byte/radix/flag/wrap cases')


if __name__=='__main__': main()
