# SPDX-License-Identifier: MIT
"""Deterministic dependent streams checked at every architectural completion.

This model uses instruction-level arithmetic and the independent event rules.
It does not import compiler, RTL, adapter, or captured expected-state helpers.
"""
import argparse
from pathlib import Path
import random
from tools.event_reference import Machine, Interruptibility, WordLimit, physical_accesses


class Stream(Machine):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.regs = [0xa500 + r for r in range(8)]
        self.control = Interruptibility()
        self.program = {}

    def registers(self):
        return self.regs[:4] + [self.sp] + self.regs[5:]

    def register(self, index, value=None):
        if value is None:
            return self.sp if index == 4 else self.regs[index]
        if index == 4:
            self.sp = value % 65536
        else:
            self.regs[index] = value % 65536

    def emit(self, ip, *code):
        self.program[ip] = list(code)
        for offset, byte in enumerate(code):
            self.memory[self.cs * 16 + ip + offset] = byte
        return ip + len(code)

    def instruction(self):
        code = self.program[self.ip]
        op = code[0]
        self.event, self.retired = None, False
        self.control.begin(self.flags)
        start = self.ip
        self.ip = (self.ip + len(code)) % 65536
        try:
            if 0xb8 <= op <= 0xbf:
                self.register(op - 0xb8, code[1] + 256 * code[2])
            elif op == 0x89 and code[1] >= 0xc0:
                self.register(code[1] % 8, self.register((code[1] // 8) % 8))
            elif op in (0x89, 0x8b) and code[1] % 8 == 6:
                offset = (self.register(5) + (code[2] if code[2] < 128 else code[2] - 256)) % 65536
                if offset == 65535:
                    raise WordLimit
                reg = (code[1] // 8) % 8
                if op == 0x89:
                    self.word(self.ss * 16 + offset, self.register(reg))
                else:
                    self.register(reg, self.word(self.ss * 16 + offset))
            elif op == 0x05:
                left, right = self.register(0), code[1] + 256 * code[2]
                result = (left + right) % 65536
                status = (int(left + right > 65535) | (int((result % 256).bit_count() % 2 == 0) << 2)
                          | (int((left % 16) + (right % 16) > 15) << 4)
                          | (int(result == 0) << 6) | ((result >> 15) << 7)
                          | (int((left < 32768) == (right < 32768) and (left < 32768) != (result < 32768)) << 11))
                self.flags = (self.flags & ~0x8d5) | status
                self.register(0, result)
            elif 0x50 <= op <= 0x57:
                self.push(self.register(op - 0x50))
            elif 0x58 <= op <= 0x5f:
                self.register(op - 0x58, self.pop())
            elif op == 0xeb:
                self.ip = (self.ip + (code[1] if code[1] < 128 else code[1] - 256)) % 65536
            elif op == 0x90:
                pass
            else:
                self.ip = start
                self.step(code)
                self.control.finish(op, fault=self.event is not None and not self.retired,
                                    software=self.event is not None and self.retired)
                if self.event is not None:
                    self.control.accept(5 if self.retired else 1)
                return
        except WordLimit:
            self.deliver(13, start)
            self.control.finish(op, fault=True)
            self.control.accept(1)
            return
        self.retired = True
        self.control.finish(op)


def scenario(seed):
    rng = random.Random(0x28660000 + seed)
    model = Stream(flags=2, sp=0x300 + seed % 2)
    for offset in range(model.sp - 96, model.sp + 16):
        model.memory[model.ss * 16 + offset] = rng.randrange(256)
    for vector in (1, 2, 3, 4, 13, 66, 80, 81):
        target = 0x1000 + vector * 64
        model.memory.update({vector * 4: target % 256, vector * 4 + 1: target // 256,
                             vector * 4 + 2: 0, vector * 4 + 3: 0x10})
        for delta in range(64):
            model.memory[0x10000 + target + delta] = 0x90
        model.emit(target, 0xcf)
    # The main stream has register dependencies, stack effects, software entry,
    # branches and IF/TF changes. The handler repairs its return IP and FLAGS.
    ip = 0x100
    ip = model.emit(ip, 0xfb)
    ip = model.emit(ip, 0xb8, rng.randrange(256), rng.randrange(256))
    for _ in range(5):
        ip = model.emit(ip, 0x05, rng.randrange(256), rng.randrange(256))
        ip = model.emit(ip, 0x50)
        ip = model.emit(ip, 0x5b)
        ip = model.emit(ip, 0x89, 0xd8)
    ip = model.emit(ip, 0xcd, 80)
    ip = model.emit(ip, 0xbb, 0xad, 0xde)  # deliberately skipped by the handler
    resume = ip
    ip = model.emit(ip, 0x05, rng.randrange(256), rng.randrange(256))
    ip = model.emit(ip, 0xcc)
    ip = model.emit(ip, 0xeb, 3)
    ip = model.emit(ip, 0xb8, 0xad, 0xde)  # wrong-path register value
    ip = model.emit(ip, 0xfa)
    ip = model.emit(ip, 0xf4)
    # Handler modifies saved IP and FLAGS using ordinary BP-relative SS MOVs.
    handler = 0x1000 + 80 * 64
    handler = model.emit(handler, 0x89, 0xe5)  # MOV BP,SP
    handler = model.emit(handler, 0xb8, resume % 256, resume // 256)
    handler = model.emit(handler, 0x89, 0x46, 0)
    replacement_flags = rng.choice((2, 0x402, 0x802, 0x102))
    handler = model.emit(handler, 0xb8, replacement_flags % 256, replacement_flags // 256)
    handler = model.emit(handler, 0x89, 0x46, 4)
    handler = model.emit(handler, 0xcd, 81)
    model.emit(handler, 0xcf)
    nested = 0x1000 + 81 * 64
    nested = model.emit(nested, 0x53)
    nested = model.emit(nested, 0xbb, rng.randrange(256), rng.randrange(256))
    nested = model.emit(nested, 0x5b)
    model.emit(nested, 0xcf)
    initial = model.memory.copy()
    checkpoints = []
    for index in range(150):
        # Seeded independent pin levels change at completed boundaries. Extra
        # edges while an NMI handler is active exercise one-slot retention.
        intr = index < 4 or (index % 17 == seed % 17 and index < 25)
        nmi = index % 13 in (seed % 13, (seed + 1) % 13) and index < 25
        model.control.pins(intr, nmi)
        event = model.control.choose(model.flags)
        model.accesses.clear()
        ack_vector = 66
        model.event, model.retired = None, False
        if event:
            kind, vector = event
            vector = ack_vector if vector is None else vector
            model.control.accept(kind)
            model.deliver(vector, model.ip)
        else:
            model.instruction()
            kind = 5 if model.event is not None and model.retired else 1 if model.event is not None else 0
        transfers = list(physical_accesses(model.accesses))
        checkpoints.append([int(intr), int(nmi), *model.registers(), model.cs, model.ip, model.flags,
                            int(model.retired), kind, model.event if model.event is not None else 256,
                            int(model.halted), int(model.control.pending_nmi), int(model.control.nmi_in_service),
                            int(bool(model.control.following_sti)), 2 if kind == 4 else 0,
                            len(transfers), *[v for t in transfers for v in t]])
        if model.halted:
            break
    else:
        raise AssertionError('bounded independent stream did not halt')
    addresses = sorted(initial)
    return [2, 0x300 + seed % 2, seed % 5, len(addresses),
            *[v for a in addresses for v in (a, initial[a], model.memory[a])],
            len(checkpoints), *[v for checkpoint in checkpoints for v in checkpoint]]


def records():
    return [scenario(seed) for seed in range(96)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    rows = records()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n' + ''.join(' '.join(f'{v:x}' for v in row) + '\n' for row in rows))
    print(f'EVENT_STREAMS: {len(rows)} deterministic dependent model histories')


if __name__ == '__main__':
    main()
