# ESC/coprocessor syntax is consumed without 80287 execution in the
# standalone no-coprocessor profile. ModR/M and displacement bytes still
# belong to the instruction stream and are acquired before retirement.
microcode_format 17

instruction ESC_NO_COPROCESSOR:
    DECODE_MODRM
    END
