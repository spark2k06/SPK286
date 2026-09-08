# Shared real-mode event services; no instruction-level timing padding.
microcode_format 5

instruction PUSH_FLAGS:
    READ_FLAGS -> TMP0
    PUSH16 DECODED TMP0
    END

instruction POP_FLAGS:
    POP16 -> TMP0
    RESTORE_FLAGS TMP0
    END

instruction CONTROL_IF:
    SET_IF DECODED
    END

instruction HALT_CPU:
    HALT
    END

instruction SOFTWARE_EVENT:
    REQUEST_EVENT DECODED
    END

instruction SOFTWARE_EVENT_IMM8:
    FETCH_IMM8 -> TMP0
    REQUEST_EVENT DECODED
    END

instruction INTERRUPT_RETURN:
    POP16 -> TMP0
    POP16 -> TMP1
    POP16 -> TMP2
    IRET_COMMIT TMP0 TMP1 TMP2
    END

instruction EVENT_ENTRY:
    EVENT_ACK
    EVENT_FLAGS -> TMP0
    PUSH16 DECODED TMP0
    EVENT_CS -> TMP0
    PUSH16 DECODED TMP0
    EVENT_IP -> TMP0
    PUSH16 DECODED TMP0
    CLEAR_IF_TF
    VECTOR_IP -> TMP0
    VECTOR_CS -> TMP1
    CONTEXT_COMMIT TMP0 TMP1
    END
