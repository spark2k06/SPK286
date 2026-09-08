"""Execute probe bytes under explicitly hypothetical policies, never as 286 evidence.

This bounded interpreter checks payload control flow, frames, memory and stimulus
mechanics. It has no prefetch, READY timing or native pin model. Instruction-start
stimulus is privileged simulation knowledge unavailable to a physical fixture.
It does not import the SPK286 RTL, compiler, event model or expected-state helpers.
"""
import argparse
import itertools
import json
from pathlib import Path

from .build import MARKERS, digest


class WordFault(Exception):
    pass


class Machine:
    def __init__(self, directory, policy):
        self.config = json.loads((directory/'config.json').read_text())
        self.policy = policy
        self.memory = bytearray([0xcc]) * (1 << 24)
        for region in self.config['regions']:
            data = (directory/region['file']).read_bytes()
            assert len(data) == region['size'] and digest(data) == region['sha256']
            self.memory[region['address']:region['address']+len(data)] = data
        self.gpr = [0]*8  # synthetic reset choice; unused GPRs are not observed
        self.seg = [0, 0xf000, 0, 0]
        self.cs_base, self.ip, self.flags = 0xff0000, 0xfff0, 2
        self.pending_nmi = self.nmi_level = self.nmi_blocked = False
        self.intr = self.owed_tf = False
        self.shadow = 0
        self.halted = False
        self.first_nmi_sent = self.target_stimulus_sent = False
        self.trace, self.events, self.markers, self.instructions = [], [], [], []

    def edge(self, level):
        if level and not self.nmi_level:
            self.pending_nmi = True
        self.nmi_level = level
        self.trace.append(dict(kind='pin', pin='NMI', value=int(level)))

    def word(self, segment, offset, value=None, role='operand'):
        if offset == 0xffff:
            raise WordFault()
        address = (segment*16+offset) & 0xffffff
        if value is None:
            value = self.memory[address] | self.memory[address+1] << 8
            write = False
        else:
            self.memory[address:address+2] = value.to_bytes(2, 'little')
            write = True
        # Logical words serialize to explicit byte lanes, without native clocks.
        transfers = [(address, 1, 0, value)] if address % 2 == 0 else [
            (address, 0, 0, (value & 255) << 8), (address+1, 1, 1, value >> 8)]
        for loc, low, bhe_n, data in transfers:
            self.trace.append(dict(kind='MEMW' if write else 'MEMR', address=loc,
                                   low_lane=low, bhe_n=bhe_n, data=data, role=role))
        if write and address in MARKERS.values():
            name = next(k for k, v in MARKERS.items() if v == address)
            assert value == 0xd286, (name, value)
            self.markers.append(name)
            if name == 'nmi_first' and self.config['stimulus'] == 'second-edge':
                self.edge(True)
                self.edge(False)
        return value

    def push(self, value, role='stack'):
        new = (self.gpr[4]-2) & 0xffff
        self.word(self.seg[2], new, value, role)
        self.gpr[4] = new

    def pop(self):
        value = self.word(self.seg[2], self.gpr[4], role='stack')
        self.gpr[4] = (self.gpr[4]+2) & 0xffff
        return value

    def deliver(self, vector, saved_ip, *, retain_tf=False):
        if vector == 0x40:
            self.trace += [dict(kind='INTA', ordinal=1, data=0x99),
                           dict(kind='INTA', ordinal=2, data=0x40)]
            self.intr = False
        frame = dict(vector=vector, saved_cs=self.seg[1], saved_ip=saved_ip,
                     saved_flags=self.flags, sp_before=self.gpr[4])
        for value in (self.flags, self.seg[1], saved_ip):
            self.push(value, 'event-frame')
        self.flags &= ~0x200 if retain_tf else ~0x300
        self.ip = self.word(0, vector*4, role='vector')
        self.seg[1] = self.word(0, vector*4+2, role='vector')
        self.cs_base = self.seg[1]*16
        frame.update(sp_after=self.gpr[4], handler_ip=self.ip)
        self.events.append(frame)
        self.trace.append(dict(kind='event-context', **frame))
        self.shadow = 0
        self.halted = False
        if vector == 2:
            self.pending_nmi = False
            self.nmi_blocked = True

    def boundary(self):
        if self.owed_tf:
            self.owed_tf = False
            self.deliver(1, self.ip)
            return True
        if self.pending_nmi and not self.nmi_blocked:
            self.deliver(2, self.ip)
            return True
        if self.intr and self.flags & 0x200 and not self.shadow:
            self.deliver(0x40, self.ip)
            return True
        return False

    def fetch(self):
        byte = self.memory[self.cs_base+self.ip]
        self.ip = (self.ip+1) & 0xffff
        return byte

    def immediate(self):
        low = self.fetch()
        return low | self.fetch() << 8

    def step(self):
        start = self.ip
        old_flags, old_shadow = self.flags, self.shadow
        opcode = self.fetch()
        self.instructions.append(dict(cs=self.seg[1], ip=start, opcode=opcode))
        self.trace.append(dict(kind='instruction-start', cs=self.seg[1], ip=start))
        if start == 0x200 and not self.target_stimulus_sent:
            self.target_stimulus_sent = True
            if self.config['stimulus'] == 'intr-after-tested-opcode':
                self.intr = True
                self.trace.append(dict(kind='pin', pin='INTR', value=1))
            elif self.config['stimulus'] == 'nmi-during-target':
                self.edge(True)
                self.edge(False)
        self.shadow = max(0, self.shadow-1)
        fault = None
        try:
            if 0xb8 <= opcode <= 0xbf:
                self.gpr[opcode-0xb8] = self.immediate()
            elif opcode == 0x8e:
                modrm = self.fetch()
                assert modrm >> 6 == 3
                self.seg[(modrm >> 3) & 3] = self.gpr[modrm & 7]
            elif opcode == 0x89:
                modrm = self.fetch()
                value = self.gpr[(modrm >> 3) & 7]
                if modrm >> 6 == 3:
                    self.gpr[modrm & 7] = value
                else:
                    assert modrm & 0xc7 == 6
                    self.word(self.seg[3], self.immediate(), value)
            elif opcode == 0x68:
                self.push(self.immediate())
            elif 0x50 <= opcode <= 0x57:
                self.push(self.gpr[opcode-0x50])
            elif opcode == 0x9c:
                self.push(self.flags)
            elif opcode == 0x6a:
                value = self.fetch()
                self.push((value-256 if value & 0x80 else value) & 0xffff)
            elif opcode == 0x9d:
                self.flags = (self.pop() & 0x0fd5) | 2
            elif opcode == 0xfa:
                self.flags &= ~0x200
            elif opcode == 0xfb:
                self.flags |= 0x200
                kind = self.policy['sti']
                self.shadow = int(kind == 'always-renew' or
                                  (kind == 'always-nonrenew' and old_shadow == 0) or
                                  (kind == 'transition' and not old_flags & 0x200))
            elif opcode == 0xcf:
                if self.policy['iret'] == 'attempt':
                    self.nmi_blocked = False
                target, selector, image = self.pop(), self.pop(), self.pop()
                self.ip, self.seg[1], self.cs_base = target, selector, selector*16
                self.flags = (image & 0xfd5) | 2
                self.nmi_blocked = False
            elif opcode == 0xea:
                target, selector = self.immediate(), self.immediate()
                self.ip, self.seg[1], self.cs_base = target, selector, selector*16
            elif opcode in (0xeb, 0xe9):
                value = self.fetch() if opcode == 0xeb else self.immediate()
                if opcode == 0xeb and value & 0x80:
                    value -= 256
                self.ip = (self.ip+value) & 0xffff
            elif opcode == 0xf4:
                self.halted = True
            elif opcode == 0x8f and self.fetch() == 0xc8:
                fault = 6
            else:
                raise AssertionError(f'unmodeled payload opcode {opcode:02x} at {start:04x}')
        except WordFault:
            fault = 13
        if fault:
            sampled = bool(old_flags & 0x100)
            self.deliver(fault, start, retain_tf=sampled and self.policy['fault_tf']=='handler-step')
            self.owed_tf = sampled and self.policy['fault_tf'] == 'immediate'
        else:
            self.owed_tf = bool(old_flags & 0x100)

    def run(self):
        for _ in range(150):
            if self.boundary():
                continue
            if self.halted:
                if self.config['family'] == 'A' and not self.first_nmi_sent:
                    self.first_nmi_sent = True
                    self.edge(True)
                    if self.config['stimulus'] != 'held-high':
                        self.edge(False)
                    continue
                break
            self.step()
        else:
            raise AssertionError('probe did not reach a bounded diagnostic stop')
        assert 'boot' in self.markers and 'armed' in self.markers
        assert 'unexpected' not in self.markers
        assert self.markers[-1] == 'dump_completed'
        # Terminal dump is DI, SI, BP, DX, CX, BX, AX, FLAGS, pre-dump SP.
        sp = self.gpr[4]
        words = [int.from_bytes(self.memory[self.seg[2]*16+sp+2*i:self.seg[2]*16+sp+2*i+2], 'little')
                 for i in range(9)]
        assert words == [self.gpr[i] for i in (7,6,5,2,1,3,0)]+[self.flags,(sp+18)&0xffff]
        return dict(schema=1, provenance='simulation', status='completed', test_id=self.config['id'],
                    policy=self.policy, events=self.events, markers=self.markers,
                    instructions=self.instructions, trace=self.trace,
                    final=dict(gpr=dict(zip(('ax','cx','dx','bx','sp','bp','si','di'), self.gpr)),
                               segments=dict(zip(('es','cs','ss','ds'), self.seg)),
                               cs=self.seg[1], ip=self.ip, flags=self.flags, sp=self.gpr[4],
                               nmi_blocked=self.nmi_blocked, pending_nmi=self.pending_nmi),
                    limitation='Synthetic instruction-boundary interpreter; not RTL, native timing or physical evidence')


def verify_result(result, config):
    vectors = [e['vector'] for e in result['events']]
    p, d = result['policy'], config['defines']
    if config['family'] == 'A':
        failed = d['IRET_SP'] != 0x9000
        second = config['stimulus'] == 'second-edge' and (not failed or p['iret']=='attempt')
        assert vectors == [2]+([13] if failed else [])+([2] if second else [])
        if failed:
            assert result['events'][1]['saved_ip'] == 0x640
            assert result['events'][1]['sp_before'] == 0xffff
        terminal = 'nmi_terminal' if second else ('gp' if failed else 'iret_success')
        assert result['markers'][-2] == terminal
    elif config['family'] == 'B':
        assert vectors == [0x40]
        following = p['sti']=='always-renew' or (not d['REPEATED_STI'] and
                     (p['sti']=='always-nonrenew' or not d['FLAGS_IMAGE'] & 0x200))
        assert ('following' in result['markers']) == following
        assert result['events'][0]['saved_ip'] == 0x201+d['REPEATED_STI']+(4 if following else 0)
    else:
        fault = d['UD_TARGET'] or d['TARGET_OFFSET'] == 0xffff
        tf = bool(d['FLAGS_IMAGE'] & 0x100)
        nmi = config['stimulus'] == 'nmi-during-target'
        if fault:
            assert vectors[0] == (6 if d['UD_TARGET'] else 13)
            assert result['events'][0]['saved_ip'] == 0x200
            assert not any(t['kind']=='MEMW' and t['address']>=0xffff and t['address']<=0x10000
                           and t['role']=='operand' for t in result['trace'])
            if nmi:
                assert vectors == ([13, 1, 2] if p['fault_tf']=='immediate' else [13, 2])
            elif tf and p['fault_tf'] != 'suppress':
                assert vectors == [vectors[0], 1]
                entry = 0x800 if d['UD_TARGET'] else 0x400
                assert result['events'][1]['saved_ip'] == entry+(4 if p['fault_tf']=='handler-step' else 0)
            elif d['RESTORE_TF']:
                assert vectors == [13, 1] and 'restored_tf' in result['markers']
            else:
                assert len(vectors) == 1
        else:
            assert vectors == [1] and result['events'][0]['saved_ip'] == 0x204


def run_all(directory, output):
    output.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((directory/'manifest.json').read_text())
    runs = []
    for case in manifest['cases']:
        path = directory/case['id']
        config = json.loads((path/'config.json').read_text())
        for iret, sti, tf in itertools.product(('attempt', 'success'),
                ('transition', 'always-renew', 'always-nonrenew'),
                ('suppress', 'immediate', 'handler-step')):
            policy = dict(iret=iret, sti=sti, fault_tf=tf)
            result = Machine(path, policy).run()
            verify_result(result, config)
            name = f'{case["id"]}--{iret}--{sti}--{tf}.json'
            data = (json.dumps(result, indent=2)+'\n').encode()
            (output/name).write_bytes(data)
            runs.append(dict(file=name, sha256=digest(data)))
    summary = dict(provenance='simulation', status='PASS', payloads=len(manifest['cases']),
                   hypothetical_policy_combinations=18, synthetic_runs=len(runs), physical_runs=0,
                   observations=runs)
    (output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(f'PROBE_MECHANICS PASS: {len(runs)} synthetic runs; physical executions=0')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--images', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run_all(args.images, args.output)
