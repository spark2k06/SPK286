#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check that a bitstream holds the design nextpnr placed and routed: decode
the frames read back by bitread to FASM features (prjxray's disassembler,
as in bit2fasm) and compare them with the FASM nextpnr wrote. Run it with
the openXC7 package's Python, which has the fasm and prjxray modules:

  tabbypy3 check_readback.py DB_ROOT PART READBACK.bits EXPECTED.fasm

Both sides go through the same canonical form, one bit per feature with
zero bits dropped. Features that set no bit in the database are not
counted on either side: they are indistinguishable from an unused setting.
"""
import sys

import fasm
import fasm.output
from prjxray import bitstream, fasm_disassembler
from prjxray.db import Database


def canonical(model):
    lines = fasm.fasm_tuple_to_string(model, canonical=True).splitlines()
    return {line.strip() for line in lines if line.strip() and not line.startswith("#")}


def sets_no_bit(disassembler, feature):
    try:
        return disassembler.is_zero_feature(feature)
    except KeyError:
        return False


def main(db_root, part, bits_file, expected_file):
    db = Database(db_root, part)
    disassembler = fasm_disassembler.FasmDisassembler(db)
    with open(bits_file) as f:
        bitdata = bitstream.load_bitdata(f)
    readback = canonical(fasm.output.merge_and_sort(
        disassembler.find_features_in_bitstream(bitdata, verbose=False),
        zero_function=disassembler.is_zero_feature))
    expected = canonical(fasm.parse_fasm_filename(expected_file))

    # Features that set no bit are equal to the cleared configuration: on
    # the expected side pseudo pips, on the read-back side the all-zero
    # encodings the disassembler names (PRECYINIT.C0, default BRAM widths)
    # that nextpnr does not write.
    missing = [f for f in sorted(expected - readback) if not sets_no_bit(disassembler, f)]
    extra = [f for f in sorted(readback - expected) if not sets_no_bit(disassembler, f)]
    print(f"features: {len(expected)} expected, {len(readback)} read back, "
          f"{len(missing)} missing, {len(extra)} unexpected")
    for name, items in (("missing", missing), ("unexpected", extra)):
        for feature in items[:10]:
            print(f"  {name}: {feature}")
    print("READBACK PASS" if not missing and not extra else "READBACK FAIL")
    return 1 if missing or extra else 0


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
