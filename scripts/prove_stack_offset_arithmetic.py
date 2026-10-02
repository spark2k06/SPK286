#!/usr/bin/env python3
"""Prove exact stack-offset mux factoring with unchanged surrounding RTL."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


REFERENCE = "792f652"
SOURCE = "rtl/spk286_micro_executor.sv"
HELPERS = ("call_parameter_write_offset", "iret_parameter_bytes", "iret_outer_stack_offset")


def assignment(source, name):
    match = re.search(r"    assign " + name + r"\s*=.*?;", source, re.S)
    if match is None:
        raise ValueError(f"Missing assignment: {name}")
    return match.group(0)


def skeleton(source, names):
    for name in names:
        source = source.replace(assignment(source, name), "")
    for name in HELPERS:
        source = re.sub(r"    \(\* keep \*\) logic \[15:0\] " + name + r";\n", "", source)
    source = re.sub(r"//[^\n]*|/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"\s+", "", source)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    candidate_bytes = (root / SOURCE).read_bytes()
    candidate = candidate_bytes.decode().replace("\r\n", "\n")
    reference_bytes = subprocess.check_output(["git", "show", f"{REFERENCE}:{SOURCE}"], cwd=root)
    reference = reference_bytes.decode().replace("\r\n", "\n")
    if skeleton(candidate, HELPERS + ("stack_offset",)) != skeleton(reference, ("stack_offset",)):
        raise ValueError("RTL outside the proven combinational mux and helpers changed")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    inputs = (
        "call_parameter_read", "call_parameter_write", "iret_outer_pop", "read_frame_address",
        "allocation_valid_q", "call_parameter_source_sp_q", "stack_cursor_q",
        "return_stack_pointer", "allocation_q", "frame_address_q", "stack_native_offset",
    )
    header = """(
    input call_parameter_read, call_parameter_write, iret_outer_pop, read_frame_address,
    input allocation_valid_q,
    input [15:0] call_parameter_source_sp_q, stack_cursor_q, return_stack_pointer,
    input [15:0] allocation_q, frame_address_q, stack_native_offset,
    output [15:0] stack_offset
);
"""
    text = ""
    instances = []
    for suffix, source, helpers in (("old", reference, ()), ("new", candidate, HELPERS)):
        text += f"module offset_{suffix}" + header
        for name in helpers:
            text += f"wire [15:0] {name};\n"
        text += "\n".join(assignment(source, name) for name in helpers + ("stack_offset",))
        text += "\nendmodule\n"
        connections = [f".{name}({name})" for name in inputs]
        connections += [f".stack_offset(stack_offset_{suffix})"]
        instances.append(f"offset_{suffix} u_{suffix} (" + ",".join(connections) + ");")
    text += "module miter" + header[:header.index("    output [15:0]")] + "    output equivalent\n);\n"
    text += "wire [15:0] stack_offset_old, stack_offset_new;\n" + "\n".join(instances) + "\n"
    text += "assign equivalent = stack_offset_old == stack_offset_new;\nendmodule\n"
    (out / "miter.v").write_text(text)
    command = "read_verilog miter.v; hierarchy -top miter; proc; flatten; opt; "
    command += "sat -verify -prove equivalent 1 -show-inputs -show-outputs"
    with (out / "proof.log").open("w") as log:
        subprocess.run(["yosys", "-p", command], cwd=out, stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    mutations = {
        "wrong_decrement": ("stack_cursor_q - 16'd2", "stack_cursor_q - 16'd1"),
        "missing_allocation": ("return_stack_pointer + iret_parameter_bytes", "return_stack_pointer"),
    }
    candidate_region = text[text.index("module offset_new"):text.index("module miter")]
    for name, (before, after) in mutations.items():
        if candidate_region.count(before) != 1:
            raise ValueError("Mutation does not target the candidate exactly once: " + name)
        mutant = text.replace(candidate_region, candidate_region.replace(before, after))
        (out / f"{name}.v").write_text(mutant)
        with (out / f"{name}.log").open("w") as log:
            result = subprocess.run(["yosys", "-p", command.replace("miter.v", f"{name}.v")],
                                    cwd=out, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode == 0 or "proof did fail" not in (out / f"{name}.log").read_text():
            raise ValueError("Negative control did not produce a SAT counterexample: " + name)
    receipt = {
        "schema": 1,
        "reference": subprocess.check_output(["git", "rev-parse", REFERENCE], cwd=root, text=True).strip(),
        "source": SOURCE,
        "reference_source_sha256": digest(reference_bytes),
        "candidate_source_sha256": digest(candidate_bytes),
        "scope": "All two-state mux inputs, including simultaneous selects, 16-bit wrap, "
                 "and allocation-valid choices; unchanged surrounding RTL and sequential logic",
        "status": "EXACT_STACK_OFFSET_EQUIVALENCE_PASS",
        "negative_controls": {name: "REJECTED" for name in mutations},
        "artifacts_sha256": {p.name: digest(p.read_bytes()) for p in out.iterdir() if p.is_file()},
    }
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("STACK_OFFSET_ARITHMETIC_FORMAL_PASS unchanged_sequential=1 mutants_rejected=2")


if __name__ == "__main__":
    main()
