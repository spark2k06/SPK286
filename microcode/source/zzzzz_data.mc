microcode_format 9
# Address acquisition and exchange use the shared operand and architectural owners.
instruction LEA_R16_M:
    DECODE_MODRM
    READ_EA -> TMP0
    TMP0 -> REG16
    END
instruction EXCHANGE_RM8_R8:
    DECODE_MODRM
    READ_RM8 -> TMP1
    READ_REG8 -> TMP0
    TMP0 -> RM8
    TMP1 -> REG8
    END
instruction EXCHANGE_RM16_R16:
    DECODE_MODRM
    READ_RM16 -> TMP1
    READ_REG16 -> TMP0
    TMP0 -> RM16
    TMP1 -> REG16
    END
instruction EXCHANGE_SOURCE_TARGET16:
    READ_DST16 -> TMP0
    READ_TARGET16 -> TMP1
    TMP1 -> SOURCE16
    TMP0 -> DST
    END
instruction LOAD_DIRECT8:
    FETCH_IMM16 -> TMP1
    SET_ADDRESS TMP1
    READ_RM8 -> TMP0
    TMP0 -> DST8
    END
instruction LOAD_DIRECT16:
    FETCH_IMM16 -> TMP1
    SET_ADDRESS TMP1
    READ_RM16 -> TMP0
    TMP0 -> DST
    END
instruction STORE_DIRECT8:
    FETCH_IMM16 -> TMP1
    SET_ADDRESS TMP1
    READ_DST8 -> TMP0
    TMP0 -> RM8
    END
instruction STORE_DIRECT16:
    FETCH_IMM16 -> TMP1
    SET_ADDRESS TMP1
    READ_DST16 -> TMP0
    TMP0 -> RM16
    END
instruction LOAD_BASE_INDEX8:
    READ_DST8 -> TMP0
    ADD_BASE TMP0 -> TMP1
    SET_ADDRESS TMP1
    READ_RM8 -> TMP0
    TMP0 -> DST8
    END
