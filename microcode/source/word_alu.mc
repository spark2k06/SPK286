# SPDX-License-Identifier: MIT
microcode_format 23

# Decode supplies the functional operation, FLAGS mask and IF_WRITE permission.
# Complete instruction-byte acquisition before any immediate-form data access.
# TMP0 is always the original destination; TMP1 is always the source.
instruction ALU_RM16_R16:
    DECODE_ALU_RM16_REG16
    READ_RM16 -> TMP0
    READ_REG16 -> TMP1
    ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED
writeback:
    TMP2 -> RM16 IF_WRITE
    COMMIT_FLAGS
    END

instruction ALU_R16_RM16:
    DECODE_ALU_REG16_RM16
    READ_REG16 -> TMP0
    READ_RM16 -> TMP1
    ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED
writeback:
    TMP2 -> REG16 IF_WRITE
    COMMIT_FLAGS
    END

instruction ALU_AX_IMM16:
    FETCH_ALU_DST16_IMM16
    FETCH_IMM16 -> TMP1
    ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED
writeback:
    TMP2 -> DST IF_WRITE
    COMMIT_FLAGS
    END

instruction ALU_RM16_IMM16:
    DECODE_MODRM
    FETCH_ALU_RM16_IMM16
    READ_RM16 -> TMP0
    ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED
writeback:
    TMP2 -> RM16 IF_WRITE
    COMMIT_FLAGS
    END

instruction ALU_RM16_IMM8S:
    DECODE_MODRM
    FETCH_ALU_RM16_IMM8S
    READ_RM16 -> TMP0
    ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED
writeback:
    TMP2 -> RM16 IF_WRITE
    COMMIT_FLAGS
    END
