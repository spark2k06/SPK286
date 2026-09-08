microcode_format 7
# Decode supplies flag masks and register selectors; no instruction timing padding.
instruction CONTROL_FLAGS:
    FLAGS DECODED
    END
instruction LOAD_FLAGS_BYTE:
    READ_FLAGS -> TMP0
    TMP0 -> DST8
    END
instruction EXTEND_BYTE:
    READ_DST16 -> TMP0
    SIGN_EXTEND8 TMP0
    TMP0 -> DST
    END
instruction EXTEND_WORD:
    READ_DST16 -> TMP0
    SIGN_FILL16 TMP0
    TMP0 -> DST
    END
instruction INC_DEC_R16:
    READ_DST16 -> TMP0
    CONST_ONE -> TMP1
    ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED
    TMP2 -> DST IF_WRITE
    COMMIT_FLAGS
    END
