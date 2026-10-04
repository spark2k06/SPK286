#!/usr/bin/env python3
"""Directed acceptance of compact provisional instruction timing metadata.

The independent caller oracle selects rows by x86 opcode/form, never by the
DUT's micro_entry case or outputs. The functional decoder supplies the real
entry to the DUT. This checks table metadata, not whole-CPU cycle accuracy.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/timing/spk286_instruction_timing.sv"
BENCH = ROOT / "sim/unit/spk286_instruction_timing_tb.sv"
PKG = ROOT / "microcode/generated/spk286_microcode_pkg.sv"
DECODER = ROOT / "rtl/spk286_decoder.sv"
TOP = "spk286_instruction_timing_tb"
PASS = "SPK286_INSTRUCTION_TIMING_PASS"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, check=True, timeout=300):
    result = subprocess.run([str(item) for item in command], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=timeout)
    log.write_text(result.stdout, newline="\n")
    if check and result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {log}")
    return result


def oracle(op, ext, mod_valid, mode, reg, rm, pm, branch_known, taken, count_known, count, rep):
    """Intel Appendix B rows and explicitly classified estimates.

    Odd corrections are real reference events in the caller, not operand_odd.
    Prefix/target length, gate/task distinctions are not silently fabricated.
    """
    mem = mode != 3
    base, estimated, need_mod, need_out, need_count = 2, 0, 0, 0, 0
    setup, iteration, wait, string = 0, 0, 1, False
    if ext:
        if op in (0, 1):
            need_mod = 1
            if op == 0:
                if reg in (0, 1): base, wait = (3 if mem else 2), 0
                elif reg in (2, 3): base = 19 if mem else 17
                elif reg in (4, 5): base = 16 if mem else 14
                else: estimated = 1
            else:
                if reg in (0, 2): base = 11
                elif reg in (1, 3): base = 12
                elif reg == 4: base = 3 if mem else 2
                elif reg == 6: base = 6 if mem else 3
                else: estimated = 1
                if reg in (0, 1, 4): wait = 0
        elif op in (2, 3): need_mod, base = 1, (16 if mem else 14)
        elif op == 5: base, estimated = 195, 1  # native LOADALL fallback
        elif op == 6: base, wait = 2, 0
        else: estimated = 1
    elif op < 0x40 and (op & 7) <= 5:
        direction = op & 7
        if direction >= 4: base, wait = 3, 0
        else:
            need_mod = 1
            base = 2 if not mem else (6 if ((op >> 3) == 7 and direction >= 2) else 7)
    elif op in (0x06, 0x0E, 0x16, 0x1E) or 0x50 <= op <= 0x57 or op in (0x68, 0x6A, 0x9C):
        base, wait = 3, 0
    elif op in (0x07, 0x17, 0x1F): base = 20 if pm else 5
    elif 0x58 <= op <= 0x5F or op in (0x9D, 0xC9): base = 5
    elif op in (0x27, 0x2F, 0x37, 0x3F): base, wait = 3, 0
    elif 0x40 <= op <= 0x4F or op in (0x98, 0x99, 0x9E, 0x9F, 0xF5, 0xF8, 0xF9, 0xFC, 0xFD, 0xF4):
        base, wait = 2, 0
    elif op in (0xFA, 0xFB): base, wait = (3 if op == 0xFA else 2), 0
    elif op == 0x60: base, wait = 17, 0
    elif op == 0x61: base = 19
    elif op == 0x62: need_mod, base = 1, 13
    elif op == 0x63: need_mod, base = 1, (11 if mem else 10)
    elif op in (0x69, 0x6B): need_mod, base = 1, (24 if mem else 21)
    elif 0x70 <= op <= 0x7F:
        need_out, base = 1, (7 if taken else 3)
        estimated = int(not branch_known or taken)
    elif op in (0x80, 0x81, 0x83):
        need_mod = 1
        base = (6 if reg == 7 else 7) if mem else 3
    elif op in (0x84, 0x85): need_mod, base = 1, (6 if mem else 2)
    elif op in (0x86, 0x87): need_mod, base = 1, (5 if mem else 3)
    elif op in (0x88, 0x89, 0xC6, 0xC7, 0x8C):
        need_mod, base, wait = 1, (3 if mem else 2), 0
    elif op in (0x8A, 0x8B): need_mod, base = 1, (5 if mem else 2)
    elif op == 0x8D: need_mod, base, wait = 1, 3, 0
    elif op == 0x8E:
        need_mod = 1
        base = (19 if mem else 17) if pm else (5 if mem else 2)
    elif op == 0x8F: need_mod, base = 1, 5
    elif 0x90 <= op <= 0x97: base, wait = 3, 0
    elif op == 0x9A: base, estimated = (26 if pm else 13), 1
    elif op == 0x9B: base, wait = 3, 0
    elif op in (0xA0, 0xA1, 0xD7): base = 5
    elif op in (0xA2, 0xA3): base, wait = 3, 0
    elif op in (0xA8, 0xA9): base, wait = 3, 0
    elif 0xB0 <= op <= 0xBF: base, wait = 2, 0
    elif op in (0xC0, 0xC1, 0xD2, 0xD3):
        need_mod, need_count = 1, 1
        base = (8 if mem else 5) + count
    elif op in (0xD0, 0xD1): need_mod, base = 1, (7 if mem else 2)
    elif op in (0xC2, 0xC3): base, estimated = 11, 1
    elif op in (0xC4, 0xC5): need_mod, base = 1, (21 if pm else 7)
    elif op == 0xC8:
        need_count = 1
        base = 11 if count == 0 else 15 if count == 1 else 12 + 4 * count
    elif op in (0xCA, 0xCB): base, estimated = (25 if pm else 15), 1
    elif op in (0xCC, 0xCD, 0xCE):
        need_out = int(op == 0xCE)
        base = 3 if op == 0xCE and not taken else 40 if pm else 24 if op == 0xCE else 23
        estimated = int(not (op == 0xCE and branch_known and not taken))
    elif op == 0xCF: base, estimated = (31 if pm else 17), 1
    elif op in (0xD4, 0xD5): base, wait = (16 if op == 0xD4 else 14), 0
    elif op == 0xD6: base, estimated, wait = 2, 1, 0
    elif 0xD8 <= op <= 0xDF: need_mod, estimated = 1, 1
    elif 0xE0 <= op <= 0xE3:
        need_out, base = 1, (8 if taken else 4)
        estimated = int(op == 0xE3 and (not branch_known or taken))
    elif op in (0xE8, 0xE9, 0xEB): base, estimated = 7, 1
    elif op == 0xEA: base, estimated = (23 if pm else 11), 1
    elif op in (0xE4, 0xE5, 0xEC, 0xED): base, wait = 5, 0
    elif op in (0xE6, 0xE7, 0xEE, 0xEF): base, wait = 3, 0
    elif op in (0xF6, 0xF7):
        need_mod = 1
        if reg == 0: base = 6 if mem else 3
        elif reg in (2, 3): base = 7 if mem else 2
        elif reg in (4, 5): base = (21 if op & 1 else 13) + (3 if mem else 0)
        elif reg == 6: base = (22 if op & 1 else 14) + (3 if mem else 0)
        elif reg == 7: base = (25 if op & 1 else 17) + (3 if mem else 0)
        else: estimated = 1
    elif op == 0xFE: need_mod, base = 1, (7 if mem else 2)
    elif op == 0xFF:
        need_mod = 1
        if reg in (0, 1): base = 7 if mem else 2
        elif reg in (2, 4): base, estimated = (11 if mem else 7), 1
        elif reg == 3: base, estimated = (29 if pm else 16), 1
        elif reg == 5: base, estimated = (26 if pm else 15), 1
        elif reg == 6: base = 5 if mem else 3
        else: estimated = 1
    elif op in (0x6C, 0x6D, 0x6E, 0x6F, 0xA4, 0xA5):
        base, setup, iteration, string = 5, 5, 4, True
    elif op in (0xA6, 0xA7): base, setup, iteration, string = 8, 5, 9, True
    elif op in (0xAA, 0xAB): base, setup, iteration, wait, string = 3, 4, 3, 0, True
    elif op in (0xAC, 0xAD):
        base, setup, iteration, string = 5, 5, 5, True
        estimated = int(rep != 0)
    elif op in (0xAE, 0xAF): base, setup, iteration, string = 7, 5, 5, True
    else:
        raise AssertionError(f"valid caller opcode lacks explicit oracle: {ext}:{op:02x}")
    ea = int(need_mod and mod_valid and mem and mode in (1, 2) and rm < 4)
    if not string or not rep:
        setup, iteration = 0, 0
        if not string and rep: estimated = 1
    elif rep == 1 and op not in (0xA6, 0xA7, 0xAE, 0xAF): estimated = 1
    qualified = int((not need_mod or mod_valid) and (not need_out or branch_known) and
                    (not need_count or count_known))
    return qualified, estimated, need_mod, need_out, need_count, base, setup, iteration, wait, ea


def vectors(path):
    normal = [op for op in range(256) if op not in
              {0x0F, 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0x82, 0xF0, 0xF1, 0xF2, 0xF3}]
    instructions = [(op, 0) for op in normal] + [(op, 1) for op in (0, 1, 2, 3, 5, 6)]
    data = []
    def append(op, ext, manual=-1, mod_valid=1, mode=3, reg=0, rm=0, pm=0,
               privilege=0, odd=0, known_branch=1, taken=0, known_count=1, count=0, rep=0,
               expected=None):
        expected = expected or oracle(op, ext, mod_valid, mode, reg, rm, pm,
                                     known_branch, taken, known_count, count, rep)
        data.append((len(data) + 1, op, ext, manual, mod_valid, mode, reg, rm, pm,
                     privilege, odd, known_branch, taken, known_count, count, rep, *expected))
    for op, ext in instructions:
        # Every accepted first opcode; all ModR/M bytes for each required form.
        needed = oracle(op, ext, 1, 3, 0, 0, 0, 1, 0, 1, 0, 0)[2]
        if needed:
            for mode in range(4):
                for reg in range(8):
                    for rm in range(8):
                        for pm in range(2): append(op, ext, mode=mode, reg=reg, rm=rm, pm=pm)
            # Missing current token must not masquerade as previous ModR/M.
            append(op, ext, mod_valid=0, mode=1, reg=7, rm=3)
        else:
            for pm in range(2): append(op, ext, pm=pm)
        # Independent ABI fields must not add odd+2 again or alter CPL cycles.
        append(op, ext, odd=1, privilege=3)
        for rep in (1, 2): append(op, ext, rep=rep)
    for op in (0xC0, 0xC1, 0xD2, 0xD3, 0xC8):
        for mode in range(4):
            for count in range(32):
                for known in (0, 1): append(op, 0, mode=mode, known_count=known, count=count)
    for op in [*range(0x70, 0x80), *range(0xE0, 0xE4), 0xCE, 0xEB]:
        for known in (0, 1):
            for taken in (0, 1): append(op, 0, known_branch=known, taken=taken)
    # Explicit external/fault event and future legal-entry fallbacks.
    constants = {name: int(value) for name, value in re.findall(
        r"(MC_ENTRY_\w+) = 10'd(\d+)", PKG.read_text())}
    for name, base in [("MC_ENTRY_EVENT_ENTRY", 23), ("MC_ENTRY_EVENT_ENTRY_PROTECTED", 40)]:
        append(0, 0, manual=constants[name], mod_valid=0, known_branch=0, known_count=0,
               expected=(1, 1, 0, 0, 0, base, 0, 0, 1, 0))
    # Internal dispatch aliases also exist in the immutable functional ROM.
    # Their independent x86 form is explicit; do not infer expectations by
    # reading the metadata module's case labels or generated trace values.
    aliases = {
        "GROUP5_NEAR": (0xFF, 0, (2, 4)),
        "NOT_RM8": (0xF6, 0, (2,)), "NOT_RM16": (0xF7, 0, (2,)),
        "NEG_RM8": (0xF6, 0, (3,)), "NEG_RM16": (0xF7, 0, (3,)),
        "INC_DEC_RM16": (0xFF, 0, (0, 1)),
        "CALL_FAR_RM": (0xFF, 0, (3,)), "JMP_FAR_RM": (0xFF, 0, (5,)),
        "MULDIV_RM8": (0xF6, 0, (4, 5, 6, 7)), "MULDIV_RM16": (0xF7, 0, (4, 5, 6, 7)),
        "SYSTEM_STORE_GDTR": (1, 1, (0,)), "SYSTEM_STORE_IDTR": (1, 1, (1,)),
        "SYSTEM_LOAD_GDTR": (1, 1, (2,)), "SYSTEM_LOAD_IDTR": (1, 1, (3,)),
        "SYSTEM_STORE_MSW": (1, 1, (4,)), "SYSTEM_LOAD_MSW": (1, 1, (6,)),
        "SYSTEM_STORE_LDTR": (0, 1, (0,)), "SYSTEM_STORE_TR": (0, 1, (1,)),
        "SYSTEM_LOAD_LDTR": (0, 1, (2,)), "SYSTEM_LOAD_TR": (0, 1, (3,)),
        "SYSTEM_VERIFY_READ": (0, 1, (4,)), "SYSTEM_VERIFY_WRITE": (0, 1, (5,)),
    }
    for name, (op, ext, regs) in aliases.items():
        for mode in range(4):
            for reg in regs:
                for rm in range(8):
                    for pm in range(2):
                        append(op, ext, manual=constants["MC_ENTRY_" + name], mode=mode,
                               reg=reg, rm=rm, pm=pm)
    append(0, 0, manual=1023, mod_valid=0, known_branch=0, known_count=0,
           expected=(1, 1, 0, 0, 0, 2, 0, 0, 1, 0))
    path.write_text("".join(" ".join(map(str, row)) + "\n" for row in data), newline="\n")
    return {"cases": len(data), "normal_opcodes": len(normal), "extended_opcodes": 6,
            "all_modrm_bytes": True, "variable_count_values": 32, "include_guard": True,
            "named_micro_entries": len(constants), "internal_dispatch_aliases": len(aliases)}


def synthesize(out):
    # Flatten only the immutable package constants for Yosys's Verilog parser;
    # the RTL logic is copied unchanged. No implementation table is generated.
    source = RTL.read_text().replace("spk286_microcode_pkg::MC_ADDR_WIDTH", "10")
    package = PKG.read_text()
    constants = "\n".join(line for line in package.splitlines() if "localparam" in line)
    source = source.replace("import spk286_microcode_pkg::*;", constants)
    flat = out / "package-expanded.sv"
    flat.write_text(source, newline="\n")
    net = out / "generic.json"
    script = out / "generic.ys"
    script.write_text(f"read_verilog -sv {flat}\nsynth -top spk286_instruction_timing -flatten\n"
                      f"write_json {net}\n", newline="\n")
    run(["yosys", "-Q", "-s", script], out / "yosys.log")
    design = json.loads(net.read_text())["modules"]["spk286_instruction_timing"]
    cells = design["cells"]
    registers = sum(len(cell["connections"].get("Q", [])) for cell in cells.values()
                    if "DFF" in cell["type"].upper())
    assert registers == 0 and not design.get("memories")
    return {"generic_cells": len(cells), "register_bits": registers, "memories": 0,
            "scope": "isolated metadata logic; not FPGA ALMs or whole CPU"}


def negatives(out):
    original = RTL.read_text()
    mutations = [
        ("immediate", "base_clocks = 10'd3; permits_read_wait = 1'b0;\n            end\n            MC_ENTRY_ALU_RM16_IMM16",
         "base_clocks = 10'd2; permits_read_wait = 1'b0;\n            end\n            MC_ENTRY_ALU_RM16_IMM16"),
        ("out", "MC_ENTRY_OUT_PORT_AL, MC_ENTRY_OUT_PORT_AX: begin\n                base_clocks = 10'd3;",
         "MC_ENTRY_OUT_PORT_AL, MC_ENTRY_OUT_PORT_AX: begin\n                base_clocks = 10'd5;"),
        ("odd-double-charge", "qualified = (!requires_modrm || modrm_valid)",
         "if (operand_odd) base_clocks = base_clocks + 10'd2;\n        qualified = (!requires_modrm || modrm_valid)"),
        ("stale-modrm", "(!requires_modrm || modrm_valid)", "1'b1"),
        ("count-truncate", "{5'd0, count};", "{6'd0, count[3:0]};"),
        ("silent-default", "default: begin base_clocks = 10'd2; estimated = 1'b1; end\n        endcase",
         "default: begin base_clocks = 10'd0; estimated = 1'b0; end\n        endcase"),
    ]
    results = {}
    for label, before, after in mutations:
        assert original.count(before) == 1, label
        directory = out / f"negative-{label}"
        directory.mkdir()
        mutated = directory / RTL.name
        mutated.write_text(original.replace(before, after), newline="\n")
        exe = directory / "test.vvp"
        run(["iverilog", "-g2012", "-I" + str(directory), "-s", TOP, "-o", exe,
             PKG, DECODER, mutated, BENCH], directory / "build.log")
        result = run(["vvp", exe, f"+vectors={out}/vectors.txt", f"+trace={directory}/trace.csv"],
                     directory / "run.log", check=False)
        marker = "instruction timing caller oracle failed"
        assert result.returncode != 0 and marker in result.stdout, label
        results[label] = {"returncode": result.returncode, "marker": marker}
    directory = out / "negative-include-guard"
    directory.mkdir()
    guarded = directory / RTL.name
    token = "`define SPK286_INSTRUCTION_TIMING_SV_INCLUDED"
    assert original.count(token) == 1
    guarded.write_text(original.replace(token, "`define WRONG_INSTRUCTION_TIMING_GUARD"), newline="\n")
    result = run(["iverilog", "-g2012", "-I" + str(directory), "-s", TOP,
                  "-o", directory / "test.vvp", PKG, DECODER, guarded, BENCH],
                 directory / "build.log", check=False)
    assert result.returncode != 0 and "already been declared" in result.stdout
    results["include-guard"] = {"returncode": result.returncode, "marker": "already been declared"}
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    if not out.is_relative_to((ROOT / "build").resolve()): parser.error("output must be under build")
    out.mkdir(parents=True, exist_ok=False)
    inputs = [RTL, BENCH, PKG, DECODER, Path(__file__).resolve()]
    before = {path.relative_to(ROOT).as_posix(): sha(path) for path in inputs}
    coverage = vectors(out / "vectors.txt")
    include = "-I" + str(RTL.parent)
    run(["verilator", "--lint-only", "--Wall", "--top-module", "spk286_instruction_timing", PKG, RTL],
        out / "lint.log")
    run(["iverilog", "-g2012", include, "-s", TOP, "-o", out / "test.vvp", PKG, DECODER, RTL, BENCH],
        out / "iverilog-build.log")
    run(["verilator", "--binary", "--timing", "--assert", "-j", "4", include,
         "--top-module", TOP, "--Mdir", out / "obj", "-o", "timing-test", PKG, DECODER, RTL, BENCH],
        out / "verilator-build.log", timeout=600)
    markers = []
    for label, command in [("iverilog", ["vvp", out / "test.vvp"]), ("verilator", [out / "obj/timing-test"])]:
        result = run([*command, f"+vectors={out}/vectors.txt", f"+trace={out}/{label}-trace.csv"],
                     out / f"{label}-run.log")
        marker = f"{PASS} cases={coverage['cases']}"
        assert marker in result.stdout
        markers.append(marker)
        with (out / f"{label}-trace.csv").open(newline="") as stream:
            rows = list(csv.DictReader(stream))
        assert len(rows) == coverage["cases"]
        assert [int(row["id"]) for row in rows] == list(range(1, len(rows) + 1))
        assert all(int(row["base"]) > 0 for row in rows)
        constants = {int(value) for value in re.findall(r"MC_ENTRY_\w+ = 10'd(\d+)", PKG.read_text())}
        assert {int(row["entry"]) for row in rows} == constants | {1023}, "named entry coverage incomplete"
    assert (out / "iverilog-trace.csv").read_bytes() == (out / "verilator-trace.csv").read_bytes()
    receipt = {"status": "PASS", "scope": "compact instruction minima metadata; provisional profiles",
               "coverage": coverage, "pass": markers, "source_sha256": before,
               "negative": negatives(out), "isolated_cost": synthesize(out),
               "artifacts_sha256": {name: sha(out / name) for name in
                   ["vectors.txt", "iverilog-trace.csv", "verilator-trace.csv"]},
               "estimated": ["taken control transfer target length", "protected gate/task variants",
                             "external/fault entry", "ESC syntax only", "LOADALL/SALC native fallback",
                             "REP LODS and untabulated REP prefix contexts"],
               "corrections_owned_by_controller": ["prefix", "actual odd-word references",
                                                  "actual extra MEMORY READ waits", "REP window selection"]}
    assert before == {path.relative_to(ROOT).as_posix(): sha(path) for path in inputs}, "sources changed"
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", newline="\n")
    print(markers[0], flush=True)
    print("SPK286_INSTRUCTION_TIMING_DUAL_NEGATIVE_COST_PASS", flush=True)


if __name__ == "__main__": main()
