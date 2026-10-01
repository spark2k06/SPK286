#!/usr/bin/env python3
"""Prove the CPU protected-memory data bypass from the actual operand RTL."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

REFERENCE = "2073e967cb7828f5c60dff57b5d15138848a1362"


def assignment(source, name):
    match = re.search(r"    assign " + name + r"\s*=.*?;", source, re.S)
    if match is None:
        raise ValueError(f"Missing assignment: {name}")
    return match.group(0)


def compact(source):
    source = re.sub(r"//[^\n]*|/\*.*?\*/", "", source, flags=re.S)
    return re.sub(r"\s+", "", source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    top = (root / "rtl/spk286.sv").read_text()
    executor = (root / "rtl/spk286_micro_executor.sv").read_text()
    operand = (root / "rtl/spk286_operand.sv").read_text()
    old = subprocess.check_output(["git", "show", f"{REFERENCE}:rtl/spk286.sv"],
                                  cwd=root, text=True)
    bypass = assignment(top, "executor_operand_read_data")
    restored = top.replace(bypass, "").replace(
        "operand_read_data, executor_operand_read_data;", "operand_read_data;").replace(
        ".operand_read_data(executor_operand_read_data)", ".operand_read_data(operand_read_data)")
    if compact(restored) != compact(old):
        raise ValueError("CPU top changed outside the proven data bypass")
    # Each service flag is exactly the executor state participating in the
    # operand selector. Abstract the remaining OR terms as an unconstrained
    # boolean: proving that stronger space also proves every actual value.
    for flag, state in (("protected_descriptor_access", "descriptor_active_q"),
                        ("protected_event_access", "event_gate_active_q"),
                        ("protected_tss_access", "call_tss_active_q")):
        if compact(assignment(executor, flag)) != f"assign{flag}={state};":
            raise ValueError(f"Protected service alias changed: {flag}")
    select = compact(assignment(executor, "operand_select_rm"))
    prefix = "assignoperand_select_rm=descriptor_active_q||event_gate_active_q||call_tss_active_q||"
    if not select.startswith(prefix):
        raise ValueError("Memory services no longer dominate operand_select_rm")
    binding = re.search(r"spk286_operand operand \((.*?)\n    \);", top, re.S).group(1)
    direct = re.search(r"\.register_direct\(([^\n]*)\),", binding).group(1)
    expected_direct = "operand_register_direct && !protected_descriptor_access && !protected_tss_access && !protected_call_stack_access && !protected_event_access && !address_override && !stack_request && !vector_request && !io_transfer"
    if compact(direct) != compact(expected_direct):
        raise ValueError("Operand register-direct qualification changed")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    text = """module miter (
    input protected_descriptor_access, protected_event_access, protected_tss_access,
    input operand_select_rm_rest, operand_register_direct, protected_call_stack_access,
    input address_override, stack_request, vector_request, io_transfer, request_byte,
    input [2:0] reg_index, rm_index,
    input [127:0] register_state,
    input [15:0] memory_read_data,
    output equivalent
);
wire select_rm, register_direct, is_memory;
wire [2:0] register_index, word_index;
wire [15:0] register_word, read_data, operand_read_data, executor_operand_read_data;
assign select_rm = protected_descriptor_access || protected_event_access || protected_tss_access || operand_select_rm_rest;
"""
    text += "assign register_direct = " + direct + ";\n"
    text += "\n".join(assignment(operand, name) for name in
                      ("register_index", "is_memory", "word_index", "register_word", "read_data"))
    text += "\nassign operand_read_data = read_data;\n" + bypass
    text += "\nassign equivalent = executor_operand_read_data == operand_read_data;\nendmodule\n"
    (out / "miter.v").write_text(text)
    command = "read_verilog miter.v; hierarchy -top miter; proc; flatten; opt; sat -verify -prove equivalent 1 -show-inputs -show-outputs"
    with (out / "proof.log").open("w") as log:
        subprocess.run(["yosys", "-p", command], cwd=out, stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    mutant = text.replace("memory_read_data : operand_read_data", "(memory_read_data ^ 16'd1) : operand_read_data")
    if mutant == text:
        raise ValueError("Negative control did not apply")
    (out / "mutant.v").write_text(mutant)
    with (out / "negative-control.log").open("w") as log:
        result = subprocess.run(["yosys", "-p", command.replace("miter.v", "mutant.v")],
                                cwd=out, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode == 0 or "proof did fail" not in (out / "negative-control.log").read_text():
        raise ValueError("Negative control did not fail the proof")
    receipt = {"schema": 1, "reference": REFERENCE, "status": "FORMAL_EQUIVALENCE_PASS",
               "scope": "all two-state data/selector inputs; actual operand data equations; "
                        "remaining select_rm OR terms unconstrained; source guards check bindings; "
                        "all surrounding CPU RTL and sequential logic unchanged",
               "negative_control": "REJECTED"}
    receipt["source_sha256"] = {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
        for name in ("rtl/spk286.sv", "rtl/spk286_operand.sv", "rtl/spk286_micro_executor.sv")}
    receipt["evidence_sha256"] = {name: hashlib.sha256((out / name).read_bytes()).hexdigest()
        for name in ("miter.v", "proof.log", "mutant.v", "negative-control.log")}
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("PROTECTED_MEMORY_DATA_FORMAL_PASS all_inputs=1 unchanged_sequential=1 mutant_rejected=1")


if __name__ == "__main__":
    main()
