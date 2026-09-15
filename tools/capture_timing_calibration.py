"""Capture and validate the Phase 9B instruction-timing calibration suite."""

from __future__ import annotations

import argparse
import csv
import json
import os
from pathlib import Path

from tools.capture_timing_trace import (
    ROOT,
    capture_input_paths as capture_trace_input_paths,
    git_status,
    hash_paths,
    manifest_relative,
    repository_relative,
    run,
    sha256_file,
)


CALIBRATION_COLUMNS = (
    "policy", "case", "start_ip", "end_ip", "final_flags", "cycles", "biu_busy_cycles",
    "accepted_transfers", "ready_wait_cycles", "prefetch_requests",
    "prefetch_responses", "queue_consumes", "operand_wait_cycles", "saw_lock",
    "final_phase", "final_status", "final_owner",
)
BASELINE_CALIBRATION_CASES = (
    ("mov_ax_imm", 0x0100, 0x0103),
    ("mov_bx_imm", 0x0103, 0x0106),
    ("alu_reg", 0x0106, 0x0108),
    ("mov_mem_read", 0x0108, 0x010C),
    ("mov_mem_write", 0x010C, 0x0110),
    ("branch_short", 0x0110, 0x0114),
)
EXTRA_CALIBRATION_CASES = (
    ("odd_word_read", 0x0100, 0x0104),
    ("near_call", 0x0100, 0x0106),
    ("near_ret", 0x0109, 0x0103),
    ("rep_movsb", 0x0100, 0x0102),
    ("int3", 0x0100, 0x0200),
    ("divide_fault", 0x0100, 0x0200),
)
CALIBRATION_CASES = BASELINE_CALIBRATION_CASES + EXTRA_CALIBRATION_CASES
EXPECTED_FINAL_FLAGS = {
    "mov_ax_imm": 0x0002,
    "mov_bx_imm": 0x0002,
    "alu_reg": 0x0006,
    "mov_mem_read": 0x0006,
    "mov_mem_write": 0x0006,
    "branch_short": 0x0006,
    "odd_word_read": 0x0002,
    "near_call": 0x0002,
    "near_ret": 0x0002,
    "rep_movsb": 0x0002,
    "int3": 0x0002,
    "divide_fault": 0x0002,
}
EXPECTED_FINAL_BUS = {
    "mov_ax_imm": (0, 15, 0),
    "mov_bx_imm": (0, 15, 0),
    "alu_reg": (0, 15, 0),
    "mov_mem_read": (0, 15, 0),
    "mov_mem_write": (0, 15, 0),
    "branch_short": (1, 13, 1),
    "odd_word_read": (1, 13, 1),
    "near_call": (1, 13, 1),
    "near_ret": (1, 13, 1),
    "rep_movsb": (0, 15, 0),
    "int3": (0, 15, 0),
    "divide_fault": (0, 15, 0),
}
UINT64_MAX = (1 << 64) - 1
COUNTER_COLUMNS = {
    "cycles", "biu_busy_cycles", "accepted_transfers", "ready_wait_cycles",
    "prefetch_requests", "prefetch_responses", "queue_consumes",
    "operand_wait_cycles",
}
NONZERO_COUNTER_COLUMNS = {
    "cycles", "biu_busy_cycles", "accepted_transfers", "prefetch_requests",
}


def read_calibration(
    path: Path,
    expected_cases: tuple[tuple[str, int, int], ...] = CALIBRATION_CASES,
) -> list[dict[str, int | str]]:
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.reader(stream)
        try:
            header = next(reader)
        except StopIteration as exc:
            raise ValueError("timing calibration is empty") from exc
        expected_columns = list(CALIBRATION_COLUMNS)
        if header != expected_columns:
            raise ValueError("timing calibration header mismatch")
        rows: list[dict[str, int | str]] = []
        for line_number, fields in enumerate(reader, start=2):
            if len(fields) != len(expected_columns):
                raise ValueError(
                    f"timing calibration row {line_number} has {len(fields)} fields; "
                    f"expected {len(expected_columns)}"
                )
            parsed: dict[str, int | str] = {"case": fields[1]}
            for column_index, name in enumerate(CALIBRATION_COLUMNS):
                if name == "case":
                    continue
                try:
                    parsed[name] = int(fields[column_index], 10)
                except ValueError as exc:
                    raise ValueError(
                        f"timing calibration row {line_number} field {name!r} is not an integer"
                    ) from exc
            rows.append(parsed)
    validate_calibration(rows, expected_cases)
    return rows


def validate_calibration(
    rows: list[dict[str, int | str]],
    expected_cases: tuple[tuple[str, int, int], ...] = CALIBRATION_CASES,
) -> None:
    expected_cases = list(expected_cases)
    if len(rows) != len(expected_cases):
        raise ValueError(f"expected {len(expected_cases)} calibration rows, got {len(rows)}")

    for index, (row, (expected_case, expected_start, expected_end)) in enumerate(
        zip(rows, expected_cases)
    ):
        if row["policy"] != 0:
            raise ValueError(f"calibration row {index} is not policy 0")
        if not 0 <= row["start_ip"] <= 0xFFFF or not 0 <= row["end_ip"] <= 0xFFFF:
            raise ValueError(f"calibration row {index} instruction IP is outside 16 bits")
        if (row["case"], row["start_ip"], row["end_ip"]) != (
            expected_case, expected_start, expected_end
        ):
            raise ValueError(f"calibration row {index} does not match expected case order")
        if not 0 <= row["final_flags"] <= 0xFFFF:
            raise ValueError(f"calibration row {index} FLAGS are outside 16 bits")
        for name in COUNTER_COLUMNS:
            value = row[name]
            if not isinstance(value, int) or value < 0:
                raise ValueError(f"calibration row {index} counter {name} is negative")
            if value > UINT64_MAX:
                raise ValueError(f"calibration row {index} counter {name} exceeds 64 bits")
            if name in NONZERO_COUNTER_COLUMNS and value == 0:
                raise ValueError(f"calibration row {index} counter {name} is unexpectedly zero")
        for name in COUNTER_COLUMNS:
            if row[name] > row["cycles"]:
                raise ValueError(
                    f"calibration row {index} counter {name} exceeds elapsed cycles"
                )
        if row["ready_wait_cycles"] != 0:
            raise ValueError("baseline calibration unexpectedly contains READY waits")
        if row["biu_busy_cycles"] != row["accepted_transfers"] + row["ready_wait_cycles"]:
            raise ValueError(f"calibration row {index} BIU busy counter is inconsistent")
        if row["saw_lock"] != 0:
            raise ValueError(f"calibration row {index} LOCK marker is not boolean")
        if (row["final_phase"], row["final_status"], row["final_owner"]) != EXPECTED_FINAL_BUS[row["case"]]:
            raise ValueError(f"calibration row {index} final bus fields do not match {row['case']}")
        if row["final_flags"] != EXPECTED_FINAL_FLAGS[row["case"]]:
            raise ValueError(f"calibration row {index} FLAGS do not match {row['case']}")

    memory_cases = {"mov_mem_read", "mov_mem_write", "odd_word_read"}
    register_cases = {"mov_ax_imm", "mov_bx_imm", "alu_reg", "branch_short"}
    for row in rows:
        if row["case"] in register_cases and row["operand_wait_cycles"] != 0:
            raise ValueError("register/ALU baseline unexpectedly waited for an operand")
        if row["case"] in memory_cases and row["operand_wait_cycles"] <= 0:
            raise ValueError("memory baseline did not observe operand service")


def validate_simulator_captures(
    simulator_rows: dict[str, list[dict[str, int | str]]],
) -> list[dict[str, int | str]]:
    """Validate every simulator before accepting cross-simulator equality."""
    if not simulator_rows:
        raise ValueError("no simulator calibration records were provided")
    first_name = next(iter(simulator_rows))
    reference = simulator_rows[first_name]
    for simulator, rows in simulator_rows.items():
        validate_calibration(rows)
        if simulator != first_name and rows != reference:
            raise RuntimeError(
                "Verilator and Icarus produced different Phase 9B calibration records"
            )
    return reference


def calibration_input_paths() -> tuple[list[Path], list[Path]]:
    compiled, support = capture_trace_input_paths()
    support = list(support) + [
        ROOT / "tools/capture_timing_calibration.py",
        ROOT / "sim/unit/spk286_timing_calibration_tb.sv",
        ROOT / "sim/unit/spk286_timing_calibration_extra_tb.sv",
    ]
    return compiled, sorted(set(support))


def capture_simulator(
    simulator: str,
    build_dir: Path,
) -> list[Path]:
    """Run the baseline and remaining-class banks for one simulator."""
    env = os.environ.copy()
    env["SPK286_BUILD_DIR"] = str(build_dir)
    run(["bash", "scripts/test_units.sh", simulator, "spk286_timing_calibration"], env=env)
    run(["bash", "scripts/test_units.sh", simulator, "spk286_timing_calibration_extra"], env=env)
    timing_dir = build_dir / "timing"
    baseline_path = timing_dir / "spk286_timing_calibration.csv"
    extra_path = timing_dir / "spk286_timing_calibration_extra.csv"
    return [baseline_path, extra_path]


CALIBRATION_BANKS = (
    ("baseline", BASELINE_CALIBRATION_CASES),
    ("extra", EXTRA_CALIBRATION_CASES),
)


def main(
    argv: list[str] | None = None,
    simulator_rows_override: dict[str, list[dict[str, int | str]]] | None = None,
) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--simulator", choices=("verilator", "iverilog", "both"), default="verilator",
        help="simulator used for the calibration capture",
    )
    parser.add_argument(
        "--build-dir", type=Path,
        default=Path(os.environ.get("SPK286_BUILD_DIR", ROOT / "build")),
        help="build/output directory (default: SPK286_BUILD_DIR or build)",
    )
    args = parser.parse_args(argv)

    if git_status():
        raise RuntimeError("timing calibration requires a clean Git tree before compilation")
    revision = run(["git", "rev-parse", "HEAD"])
    branch = run(["git", "branch", "--show-current"])
    compiled_inputs, support_inputs = calibration_input_paths()
    input_hashes_before = hash_paths(compiled_inputs + support_inputs)

    build_dir = args.build_dir if args.build_dir.is_absolute() else ROOT / args.build_dir
    timing_dir = build_dir / "timing"
    timing_dir.mkdir(parents=True, exist_ok=True)
    csv_path = timing_dir / "spk286_timing_calibration.csv"
    manifest_path = timing_dir / "spk286_timing_calibration.json"

    simulators = ("verilator", "iverilog") if args.simulator == "both" else (args.simulator,)
    simulator_rows: dict[str, list[dict[str, int | str]]] = {}
    simulator_paths: dict[str, list[Path]] = {}
    simulator_versions: dict[str, str] = {}
    if simulator_rows_override is None:
        for simulator in simulators:
            # Keep raw bank outputs outside the combined-output directory even
            # for a single simulator.  The combined CSV is an evidence product,
            # not a replacement for either original bank capture.
            capture_build_dir = build_dir / f"phase9b-{simulator}"
            paths_for_simulator = capture_simulator(simulator, capture_build_dir)
            simulator_paths[simulator] = paths_for_simulator
            version_command = [simulator, "-V"] if simulator == "iverilog" else [simulator, "--version"]
            simulator_versions[simulator] = run(version_command).splitlines()[0]
        # Parse every simulator's original bank output only after both
        # simulators have produced their files.  A malformed pair is therefore
        # rejected as a pair and never reaches manifest publication.
        for simulator in simulators:
            baseline_path, extra_path = simulator_paths[simulator]
            simulator_rows[simulator] = (
                read_calibration(baseline_path, BASELINE_CALIBRATION_CASES)
                + read_calibration(extra_path, EXTRA_CALIBRATION_CASES)
            )
    else:
        simulator_rows = simulator_rows_override

    rows = validate_simulator_captures(simulator_rows)
    if git_status():
        raise RuntimeError("Git tree changed while timing calibration was running")
    if run(["git", "rev-parse", "HEAD"]) != revision:
        raise RuntimeError("HEAD changed while timing calibration was running")
    input_hashes_after = hash_paths(compiled_inputs + support_inputs)
    if input_hashes_after != input_hashes_before:
        raise RuntimeError("calibration inputs changed while timing calibration was running")

    with csv_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=CALIBRATION_COLUMNS)
        writer.writeheader()
        writer.writerows(rows)

    simulator_version: str | dict[str, str]
    if len(simulators) == 1:
        simulator_version = simulator_versions[simulators[0]]
    else:
        simulator_version = simulator_versions
    manifest = {
        "schema_version": 2,
        "source_revision": revision,
        "branch": branch,
        "working_tree": {"clean": True, "status": ""},
        "simulator": args.simulator,
        "simulator_version": simulator_version,
        "timing_policy": {
            "id": 0,
            "name": "normalized-functional-baseline",
            "historical_cycle_accuracy_claim": False,
        },
        "target": "80286-oriented instruction classes; no historical timing claim",
        "reference_evidence": {
            "documented_target": "Intel 80286 instruction architecture",
            "physical_trace": None,
            "level": "normalized functional observation",
        },
        "calibration": {
            "path": manifest_relative(csv_path, manifest_path),
            "path_base": "manifest_directory",
            "repository_path": repository_relative(csv_path),
            "sha256": sha256_file(csv_path),
            "columns": list(CALIBRATION_COLUMNS),
            "records": len(rows),
            "rows": [dict(row) for row in rows],
        },
        "simulator_outputs": {
            simulator: [
                {
                    "bank": bank_name,
                    "path": manifest_relative(path, manifest_path),
                    "path_base": "manifest_directory",
                    "repository_path": repository_relative(path),
                    "sha256": sha256_file(path),
                    "columns": list(CALIBRATION_COLUMNS),
                    "records": len(read_calibration(path, expected_cases)),
                    "cases": [case for case, _, _ in expected_cases],
                }
                for (bank_name, expected_cases), path in zip(
                    CALIBRATION_BANKS, simulator_paths[simulator]
                )
            ]
            for simulator in simulators
        },
        "input_hashes": dict(input_hashes_before),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        "TIMING CALIBRATION MANIFEST PASS: "
        f"{manifest_path} records={len(rows)} sha256={manifest['calibration']['sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
