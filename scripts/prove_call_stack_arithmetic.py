#!/usr/bin/env python3
"""Prove the P05 call-stack arithmetic rewrite against its committed source."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


REFERENCE = "2073e96"
SOURCE = "rtl/spk286_micro_executor.sv"
HELPERS = ("call_gate_frame_words", "call_parameter_last_word", "call_parameter_last_byte")


def assignment(source, name):
    match = re.search(r"    assign " + name + r"\s*=.*?;", source, re.S)
    if match is None:
        raise ValueError(f"Missing assignment: {name}")
    return match.group(0)


def skeleton(source, names):
    for name in names:
        source = source.replace(assignment(source, name), "")
    for name in HELPERS:
        source = re.sub(r"    logic \[\d+:0\] " + name + r";\n", "", source)
    # Comments and whitespace cannot alter RTL outside the proven assignments.
    source = re.sub(r"//[^\n]*|/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"\s+", "", source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    current = (root / SOURCE).read_text()
    reference = subprocess.check_output(
        ["git", "show", f"{REFERENCE}:{SOURCE}"], cwd=root, text=True)
    names = ("call_gate_frame_bytes", "call_stack_range_fault")
    if skeleton(current, names + HELPERS) != skeleton(reference, names):
        raise ValueError("RTL outside the proven combinational assignments changed")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    header = """(
    input [4:0] call_gate_parameter_count_q,
    input event_gate_candidate_valid_q, event_error_valid,
    input check_call_frame, event_active, call_gate_outer_required,
    input call_stack_ready_q,
    input [15:0] protected_msw, call_stack_sp_q, call_ss_limit_q,
    input [7:0] call_ss_access_q, stack_segment_access,
    input [15:0] stack_pointer, stack_segment_limit,
    output [16:0] call_gate_frame_bytes,
    output call_stack_range_fault
);
"""
    instances = []
    inputs = ("call_gate_parameter_count_q", "event_gate_candidate_valid_q", "event_error_valid",
              "check_call_frame", "event_active", "call_gate_outer_required", "call_stack_ready_q",
              "protected_msw", "call_stack_sp_q", "call_ss_limit_q", "call_ss_access_q",
              "stack_segment_access", "stack_pointer", "stack_segment_limit")
    text = ""
    for suffix, source, helpers in (("old", reference, ()), ("new", current, HELPERS)):
        text += f"module arithmetic_{suffix}" + header
        if helpers:
            text += "wire [5:0] call_gate_frame_words;\nwire [4:0] call_parameter_last_word;\n"
            text += "wire [16:0] call_parameter_last_byte;\n"
        text += "\n".join(assignment(source, name) for name in helpers + names) + "\nendmodule\n"
        connections = [f".{name}({name})" for name in inputs]
        connections += [f".{name}({name}_{suffix})" for name in names]
        instances.append(f"arithmetic_{suffix} u_{suffix} (" + ",".join(connections) + ");")
    miter_header = header[:header.index("    output [16:0]")] + "    output equivalent\n);\n"
    text += "module miter" + miter_header
    text += "wire [16:0] call_gate_frame_bytes_old, call_gate_frame_bytes_new;\n"
    text += "wire call_stack_range_fault_old, call_stack_range_fault_new;\n"
    text += "\n".join(instances) + "\n"
    text += "assign equivalent = (call_gate_frame_bytes_old == call_gate_frame_bytes_new) &&\n"
    text += "                    (call_stack_range_fault_old == call_stack_range_fault_new);\nendmodule\n"
    (out / "miter.v").write_text(text)
    yosys_script = "read_verilog miter.v; hierarchy -top miter; proc; flatten; opt; "
    yosys_script += "sat -verify -prove equivalent 1 -show-inputs -show-outputs"
    with (out / "proof.log").open("w") as log:
        subprocess.run(["yosys", "-p", yosys_script], cwd=out, stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    # A broken last-byte equation must fail the same proof. This checks that
    # the miter observes real parameter boundaries rather than tying a guard off.
    mutated = text.replace("call_gate_parameter_count_q - 5'd1", "call_gate_parameter_count_q")
    if mutated == text:
        raise ValueError("Negative-control mutation did not apply")
    (out / "mutant.v").write_text(mutated)
    with (out / "negative-control.log").open("w") as log:
        result = subprocess.run(["yosys", "-p", yosys_script.replace("miter.v", "mutant.v")],
                                cwd=out, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode == 0 or "proof did fail" not in (out / "negative-control.log").read_text():
        raise ValueError("Negative control did not produce a SAT counterexample")
    receipt = {"schema": 1, "reference": subprocess.check_output(
        ["git", "rev-parse", REFERENCE], cwd=root, text=True).strip(),
        "reference_source_sha256": hashlib.sha256(reference.encode()).hexdigest(),
        "candidate_source_sha256": hashlib.sha256(current.encode()).hexdigest(),
        "scope": "all two-state inputs; exact frame-byte and call-stack-fault equivalence; "
                 "unchanged surrounding RTL including sequential logic",
        "status": "FORMAL_EQUIVALENCE_PASS", "negative_control": "REJECTED"}
    for name in ("miter.v", "proof.log", "mutant.v", "negative-control.log"):
        receipt[name + "_sha256"] = hashlib.sha256((out / name).read_bytes()).hexdigest()
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("CALL_STACK_ARITHMETIC_FORMAL_PASS all_inputs=1 unchanged_sequential=1 mutant_rejected=1")


if __name__ == "__main__":
    main()
