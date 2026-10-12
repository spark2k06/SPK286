# SPDX-License-Identifier: MIT
microcode_format 21

# Undocumented 80286 SALC: AL = CF ? FFh : 00h; preserve AH and all FLAGS.
# Transform a captured FLAGS value, then use the ordinary byte register owner.
instruction LOAD_CARRY_BYTE:
    READ_FLAGS -> TMP0
    CARRY_FILL8 TMP0
    TMP0 -> DST8
    END
