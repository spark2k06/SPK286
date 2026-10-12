# SPDX-License-Identifier: MIT
microcode_format 23

# One shared entry; the decoder supplies the word-register destination.
instruction MOV_R16_IMM16:
    FETCH_MOV_DST16_IMM16
writeback:
    TMP0 -> DST
    END

instruction MOV_RM16_R16:
    DECODE_MOV_RM16_REG16
    READ_REG16 -> TMP0
writeback:
    TMP0 -> RM16
    END

instruction MOV_R16_RM16:
    DECODE_MOV_REG16_RM16
    READ_RM16 -> TMP0
writeback:
    TMP0 -> REG16
    END
