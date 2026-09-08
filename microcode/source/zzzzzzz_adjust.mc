microcode_format 11
# Arithmetic flags precede the explicit fault check, including zero-radix AAM.
instruction ADJUST_DIRECT:
    READ_DST16 -> TMP0
    CONST_ZERO -> TMP1
    ADJUST DECODED TMP0 TMP1 -> TMP2 FLAGS_DECODED
    TMP2 -> DST IF_WRITE
    COMMIT_FLAGS
    CHECK_ARITHMETIC
    END
instruction ADJUST_RADIX:
    FETCH_IMM8 -> TMP1
    READ_DST16 -> TMP0
    ADJUST DECODED TMP0 TMP1 -> TMP2 FLAGS_DECODED
    TMP2 -> DST IF_WRITE
    COMMIT_FLAGS
    CHECK_ARITHMETIC
    END
