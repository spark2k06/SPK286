#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Copy a Verilog cell library without some of its modules.

  strip_cells.py INPUT.v OUTPUT.v MODULE...

run_netlist_sim.sh uses it to take RAMB18E1 and RAMB36E1, which have no
behaviour in Yosys's cells_sim.v, out of the library it simulates with.
"""
from pathlib import Path
import re
import sys


def main(source, target, names):
    text = Path(source).read_text()
    for name in names:
        text, count = re.subn(rf"^module {name} \(.*?^endmodule\n", "", text, flags=re.M | re.S)
        if count != 1:
            sys.exit(f"{source}: {count} definitions of {name}")
    Path(target).write_text(text)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
