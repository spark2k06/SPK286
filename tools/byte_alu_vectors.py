"""Exhaustive byte arithmetic expectations using integers and signed ranges."""
import argparse
from pathlib import Path

def write_vectors(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w', encoding='ascii', newline='\n') as f:
        count=0
        for op in range(7):
            for a in range(256):
                for b in range(256):
                    for carry in (range(2) if op in (2,3) else range(1)):
                        borrow=op in (3,5)
                        arithmetic=op in (0,2,3,5)
                        if arithmetic:
                            full=a-b-carry if borrow else a+b+carry
                            nibble=(a%16)-(b%16)-carry if borrow else (a%16)+(b%16)+carry
                            sa=a-256 if a>=128 else a;sb=b-256 if b>=128 else b
                            signed=sa-sb-carry if borrow else sa+sb+carry
                            flags=int(full<0 or full>255)|(int(nibble<0 or nibble>15)<<4)|(int(signed < -128 or signed > 127)<<11)
                        else:
                            full=(a|b) if op==1 else ((a&b) if op==4 else (a^b));flags=0
                        value=full%256
                        flags|=int(value.bit_count()%2==0)<<2|int(value==0)<<6|int(value>=128)<<7
                        f.write(f'{op:x} {a:04x} {b:04x} {carry:x} {value:04x} {flags:04x}\n')
                        count+=1
    return count

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    print(f'BYTE_ALU_VECTORS PASS: {write_vectors(args.output)} independent cases')
