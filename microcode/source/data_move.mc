microcode_format 1

# One shared entry; the decoder supplies the word-register destination.
instruction MOV_R16_IMM16:
    FETCH_IMM16 -> TMP0
writeback:
    TMP0 -> DST
    END
