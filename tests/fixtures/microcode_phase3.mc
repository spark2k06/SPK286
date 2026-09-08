microcode_format 2

# One shared entry; the decoder supplies the word-register destination.
instruction MOV_R16_IMM16:
    FETCH_IMM16 -> TMP0
writeback:
    TMP0 -> DST
    END

instruction MOV_RM16_R16:
    DECODE_MODRM
    READ_REG16 -> TMP0
writeback:
    TMP0 -> RM16
    END

instruction MOV_R16_RM16:
    DECODE_MODRM
    READ_RM16 -> TMP0
writeback:
    TMP0 -> REG16
    END
