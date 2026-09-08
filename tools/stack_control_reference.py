"""Independent Intel 80286 stack/near-control arithmetic and instruction oracle.

No production decoder, microcode compiler, corpus adapter or RTL encodings are
imported. Transactions are logical words; the vector writer expands bus lanes.
"""
from dataclasses import dataclass


def signed(value, bits):
    return value - (1 << bits) if value >= 1 << (bits - 1) else value


def condition(code, flags):
    c, p, z, s, o = (bool(flags & (1 << bit)) for bit in (0, 2, 6, 7, 11))
    return (o, not o, c, not c, z, not z, c or z, not c and not z,
            s, not s, p, not p, s != o, s == o, z or s != o, not z and s == o)[code]


def relative(next_ip, displacement):
    return (next_ip + displacement) % 65536


def push(sp, value):
    offset = (sp - 2) % 65536
    if offset == 65535:
        raise ValueError('stack word exceeds limit')
    return offset, value % 65536


def pop(sp, value, destination_sp=False, release=0):
    if sp == 65535:
        raise ValueError('stack word exceeds limit')
    return value % 65536 if destination_sp else (sp + 2 + release) % 65536


def loop(opcode, count, flags):
    updated = count if opcode == 0xe3 else (count - 1) % 65536
    taken = (updated == 0 if opcode == 0xe3 else updated != 0 and
             (opcode == 0xe2 or bool(flags & 64) == (opcode == 0xe1)))
    return updated, taken


@dataclass
class Outcome:
    registers: list
    ip: int
    memory: dict
    transactions: list
    blocked: bool
    redirected: bool


def evaluate(code, registers, flags, ip, memory):
    r, ram, transactions = list(registers), dict(memory), []
    next_ip = (ip + len(code)) % 65536
    target, redirected = next_ip, False
    op = code[0]
    def word(address):
        return ram.get(address, 0) + 256 * ram.get(address+1, 0)
    def access(write, address, value=0):
        if not write:
            value = word(address)
        transactions.append((write, address, value))
        if write:
            ram[address], ram[address+1] = value % 256, value // 256
        return value
    def stack_push(value):
        offset, value = push(r[4], value)
        access(True, 0x80000+offset, value)
        r[4] = offset
    def stack_pop():
        sp = r[4]
        r[4] = pop(sp, 0)
        return access(False, 0x80000+sp)
    def operand(check_limit=True):
        mod, reg, rm = code[1] // 64, (code[1] // 8) % 8, code[1] % 8
        if mod == 3:
            return reg, rm, None
        disp = (signed(code[2], 8) if mod == 1 else code[2]+256*code[3]
                if mod == 2 or rm == 6 and mod == 0 else 0)
        base = (r[3]+r[6], r[3]+r[7], r[5]+r[6], r[5]+r[7], r[6], r[7], r[5], r[3])[rm]
        offset = disp if mod == 0 and rm == 6 else (base+disp) % 65536
        if check_limit and offset == 65535:
            raise ValueError('operand word exceeds limit')
        ss = rm in (2,3) or rm == 6 and mod != 0
        return reg, rm, (0x80000 if ss else 0x40000)+offset
    try:
        if 0x50 <= op <= 0x57:
            stack_push(r[op-0x50])
        elif 0x58 <= op <= 0x5f:
            r[op-0x58] = stack_pop()
        elif op in (0x68, 0x6a):
            stack_push(code[1]+256*code[2] if op == 0x68 else signed(code[1],8) % 65536)
        elif op == 0x8f:
            reg, rm, address = operand(check_limit=False)
            if reg != 0:
                raise ValueError('unsupported POP group')
            value = stack_pop()
            if address is not None and address % 65536 == 65535:
                raise ValueError('POP destination word exceeds limit after stack read')
            if address is None:
                r[rm] = value
            else:
                access(True, address, value)
        elif op == 0xff:
            reg, rm, address = operand()
            if reg not in (2,4,6):
                raise ValueError('unsupported group 5')
            value = r[rm] if address is None else access(False, address)
            if reg in (2,6):
                stack_push(next_ip if reg == 2 else value)
            if reg in (2,4):
                target, redirected = value, True
        elif op in (0xc2,0xc3):
            target, redirected = stack_pop(), True
            if op == 0xc2:
                r[4] = (r[4]+code[1]+256*code[2]) % 65536
        elif op in (0xe8,0xe9,0xeb) or 0x70 <= op <= 0x7f:
            disp = code[1]+256*code[2] if op in (0xe8,0xe9) else signed(code[1],8)
            redirected = condition(op-0x70,flags) if op < 0x80 else True
            if op == 0xe8:
                stack_push(next_ip)
            if redirected:
                target = relative(next_ip,disp)
        elif 0xe0 <= op <= 0xe3:
            r[1], redirected = loop(op,r[1],flags)
            if redirected:
                target = relative(next_ip,signed(code[1],8))
        else:
            raise ValueError('unsupported instruction')
    except ValueError:
        return Outcome(r, next_ip, ram, transactions, True, False)
    return Outcome(r, target, ram, transactions, False, redirected)
