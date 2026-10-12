# SPDX-License-Identifier: MIT
microcode_format 12
# Cached source and completed stack/operand transfer precede architectural cache writes.
instruction MOV_RM16_SEG:
    DECODE_MODRM
    READ_SEG16 -> TMP0
    TMP0 -> RM16
    END
instruction MOV_SEG_RM16:
    DECODE_MODRM
    READ_RM16 -> TMP0
    TMP0 -> SEG16
    END
instruction PUSH_SEG:
    READ_SEG16 -> TMP0
    PUSH16 DECODED TMP0
    END
instruction POP_SEG:
    POP16 -> TMP0
    TMP0 -> SEG16
    END
