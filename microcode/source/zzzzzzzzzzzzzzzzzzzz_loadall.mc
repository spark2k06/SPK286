# SPDX-License-Identifier: MIT
microcode_format 21

# Undocumented but guaranteed 80286 LOADALL. The RTL service owns the
# serialized physical image acquisition; this entry is its microcode token.
instruction LOADALL:
    LOADALL
    END
