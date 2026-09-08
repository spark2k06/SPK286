microcode_format 6
# Explicit byte widths; original word and event programs retain their controls.
instruction MOV_R8_IMM8:
    FETCH_IMM8 -> TMP0
    TMP0 -> DST8
    END
instruction MOV_RM8_R8:
    DECODE_MODRM
    READ_REG8 -> TMP0
    TMP0 -> RM8
    END
instruction MOV_R8_RM8:
    DECODE_MODRM
    READ_RM8 -> TMP0
    TMP0 -> REG8
    END
instruction MOV_RM8_IMM8:
    DECODE_MODRM
    FETCH_IMM8 -> TMP0
    TMP0 -> RM8
    END
instruction MOV_RM16_IMM16:
    DECODE_MODRM
    FETCH_IMM16 -> TMP0
    TMP0 -> RM16
    END
instruction ALU_RM8_R8:
    DECODE_MODRM
    READ_RM8 -> TMP0
    READ_REG8 -> TMP1
    ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED
    TMP2 -> RM8 IF_WRITE
    COMMIT_FLAGS
    END
instruction ALU_R8_RM8:
    DECODE_MODRM
    READ_REG8 -> TMP0
    READ_RM8 -> TMP1
    ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED
    TMP2 -> REG8 IF_WRITE
    COMMIT_FLAGS
    END
instruction ALU_AL_IMM8:
    READ_DST8 -> TMP0
    FETCH_IMM8 -> TMP1
    ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED
    TMP2 -> DST8 IF_WRITE
    COMMIT_FLAGS
    END
instruction ALU_RM8_IMM8:
    DECODE_MODRM
    FETCH_IMM8 -> TMP1
    READ_RM8 -> TMP0
    ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED
    TMP2 -> RM8 IF_WRITE
    COMMIT_FLAGS
    END
