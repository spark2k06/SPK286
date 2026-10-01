# CPU-side NPX checks for the standalone no-coprocessor profile.
# ESC tests EM || TS before acquiring ModR/M/displacement; a successful
# check validates the first word without transferring an operand to an NPX.
# WAIT tests MP && TS with BUSY inactive.
microcode_format 27

instruction ESC_NO_COPROCESSOR:
    CHECK_NPX_ESC
    DECODE_MODRM
    CHECK_RM16
    END

instruction WAIT_NO_COPROCESSOR:
    CHECK_NPX_WAIT
    END
