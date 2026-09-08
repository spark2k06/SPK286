"""Frozen Phase 6 physical-family membership, independent of future admission.

Pinned corpus 37c73caf53dcd22d3dd369ff09305d13d117a4fe. Prefix exclusions
and the 440574/1423/32052 cohorts remain historical identities, not active ISA
coverage. New Phase 7 families must use a separate manifest and accounting.
"""
MOV_OPCODES = tuple(f'{value:02X}' for value in range(0xB8, 0xC0)) + ('89', '8B')
ALU_OPCODES = tuple(f'{group * 8 + form:02X}' for group in range(8) for form in (1, 3, 5)) + tuple(
    f'{opcode}.{group}' for opcode in ('81', '83') for group in range(8))
STACK_CONTROL_OPCODES = tuple(f'{value:02X}' for value in range(0x50, 0x60)) + ('68', '6A') + tuple(
    f'{value:02X}' for value in range(0x70, 0x80)) + (
        '8F', 'C2', 'C3', 'E0', 'E1', 'E2', 'E3', 'E8', 'E9', 'EB', 'FF.2', 'FF.4', 'FF.6')
INHERITED_OPCODES = MOV_OPCODES + ALU_OPCODES + STACK_CONTROL_OPCODES
PHASE6_OPCODES = ('9C', '9D', 'CC', 'CD', 'CE', 'CF', 'F4', 'FA', 'FB')
SUPPORTED_OPCODES = INHERITED_OPCODES + PHASE6_OPCODES
