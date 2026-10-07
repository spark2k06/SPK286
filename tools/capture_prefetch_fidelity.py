"""Capture and validate the integrated prefetch observation bank."""

from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
from pathlib import Path

from tools.capture_timing_trace import (
    ROOT,
    capture_input_paths,
    git_status,
    hash_paths,
    manifest_relative,
    repository_relative,
    run,
    sha256_file,
)


TRACE_COLUMNS = (
    "scenario", "epoch", "cycle", "reset", "queue_count",
    "model_queue_count", "model_queue_count_after", "model_pending_count",
    "model_pending_count_after", "bus_valid", "bus_status", "address",
    "bhe_n", "ready", "code_accept", "model_code_accept",
    "fetch_response_valid", "response_accept", "response_count",
    "response_data", "consume_valid", "consume_accept", "consume_data",
    "expected_consume", "restart", "invalidated_pending",
    "instruction_wait", "operand_wait", "data_wait", "fetch_bus_valid",
    "fetch_response_ready", "queue_empty_cycles", "prefetch_requests",
    "prefetch_responses", "queue_consumes", "redirects", "cancels",
    "halted", "debug_ip", "fetch_cursor", "fetch_request_internal",
    "queue_empty_fetch_activity", "execution_allowed", "micro_active",
    "decode_ready", "executor_byte_ready", "queue_consume_valid",
    "event_active", "event_request", "event_completed", "raw_retired",
    "operand_blocked", "unsupported", "byte_demand", "hlt_resume",
)
BOOLEAN_COLUMNS = {
    "reset", "bus_valid", "bhe_n", "ready", "code_accept",
    "model_code_accept", "fetch_response_valid", "response_accept",
    "consume_valid", "consume_accept", "restart", "invalidated_pending",
    "instruction_wait", "operand_wait", "data_wait", "fetch_bus_valid",
    "fetch_response_ready", "halted", "fetch_request_internal",
    "queue_empty_fetch_activity", "execution_allowed", "micro_active",
    "decode_ready", "executor_byte_ready", "queue_consume_valid",
    "event_active", "event_request", "event_completed", "raw_retired",
    "operand_blocked", "unsupported", "byte_demand", "hlt_resume",
}
COUNTER_COLUMNS = {
    "queue_empty_cycles", "prefetch_requests", "prefetch_responses",
    "queue_consumes", "redirects", "cancels",
}
UINT64_MAX = (1 << 64) - 1


def read_capture(path: Path) -> list[dict[str, int]]:
    """Read a capture and reject malformed rows before any summary is made."""
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.reader(stream)
        try:
            header = next(reader)
        except StopIteration as exc:
            raise ValueError("prefetch capture is empty") from exc
        expected = list(TRACE_COLUMNS)
        if header != expected:
            raise ValueError(
                f"prefetch capture header mismatch: expected {len(expected)} ordered columns, "
                f"got {len(header)}"
            )
        rows: list[dict[str, int]] = []
        for line_number, fields in enumerate(reader, start=2):
            if len(fields) != len(expected):
                raise ValueError(
                    f"prefetch capture row {line_number} has {len(fields)} fields; "
                    f"expected {len(expected)}"
                )
            parsed: dict[str, int] = {}
            for name, value in zip(expected, fields):
                try:
                    parsed[name] = int(value, 10)
                except ValueError as exc:
                    raise ValueError(
                        f"prefetch capture row {line_number} field {name!r} is not an integer"
                    ) from exc
            rows.append(parsed)
    validate_capture_rows(rows)
    return rows


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def validate_capture_rows(rows: list[dict[str, int]]) -> None:
    """Validate the independent reference-model transitions and observations."""
    _require(rows, "prefetch capture contains no data rows")
    expected = set(TRACE_COLUMNS)
    previous: dict[str, int] | None = None
    previous_halted = False
    for index, row in enumerate(rows):
        _require(set(row) == expected, f"prefetch row {index} fields differ")
        for name in BOOLEAN_COLUMNS:
            _require(row[name] in (0, 1), f"prefetch row {index} field {name} is not boolean")
        _require(row["scenario"] >= 1, f"prefetch row {index} has invalid scenario")
        _require(row["epoch"] >= 0, f"prefetch row {index} has negative epoch")
        _require(row["cycle"] >= 0, f"prefetch row {index} has negative cycle")
        _require(0 <= row["queue_count"] <= 6, f"prefetch row {index} queue count is outside 0..6")
        _require(0 <= row["model_queue_count"] <= 6, f"prefetch row {index} model queue count is outside 0..6")
        _require(0 <= row["model_queue_count_after"] <= 6, f"prefetch row {index} model queue transition is outside 0..6")
        _require(0 <= row["model_pending_count"] <= 2, f"prefetch row {index} pending count is outside 0..2")
        _require(0 <= row["model_pending_count_after"] <= 2, f"prefetch row {index} pending transition is outside 0..2")
        _require(0 <= row["bus_status"] <= 15, f"prefetch row {index} status is outside 0..15")
        _require(0 <= row["address"] <= 0xFFFFFF, f"prefetch row {index} address is outside 24 bits")
        _require(0 <= row["response_count"] <= 2, f"prefetch row {index} response count is outside 0..2")
        _require(0 <= row["response_data"] <= 0xFFFF, f"prefetch row {index} response data is outside 16 bits")
        _require(-1 <= row["expected_consume"] <= 0xFF, f"prefetch row {index} expected byte is invalid")
        for name in COUNTER_COLUMNS | {"cycle", "debug_ip", "fetch_cursor"}:
            _require(row[name] >= 0, f"prefetch row {index} field {name} is negative")
            _require(row[name] <= UINT64_MAX, f"prefetch row {index} field {name} exceeds 64 bits")

        same_scenario = previous is not None and row["scenario"] == previous["scenario"]
        expected_hlt_resume = int(
            not row["reset"] and same_scenario and previous_halted and
            not row["halted"] and row["event_active"]
        )
        _require(row["hlt_resume"] == expected_hlt_resume,
                 f"prefetch row {index} HLT resume marker does not match the observed transition")

        if row["reset"]:
            for name in ("model_queue_count", "model_queue_count_after",
                         "model_pending_count", "model_pending_count_after",
                         "code_accept", "model_code_accept",
                         "response_accept", "consume_accept", "restart",
                         "invalidated_pending", "instruction_wait", "operand_wait",
                         "data_wait", "queue_empty_fetch_activity", "byte_demand",
                         "hlt_resume"):
                _require(row[name] == 0, f"prefetch reset row {index} has {name} activity")
            _require(row["expected_consume"] == -1,
                     f"prefetch reset row {index} has an expected byte")
        else:
            _require(row["queue_count"] == row["model_queue_count"],
                     f"prefetch row {index} DUT queue differs from reference before edge")
            if row["bus_valid"]:
                _require(row["bus_status"] != 15, f"prefetch row {index} active bus has idle status")
                _require(row["bhe_n"] in (0, 1), f"prefetch row {index} has invalid BHE")
            else:
                _require(row["bus_status"] in (4, 15),
                         f"prefetch row {index} idle bus has active status")
                if row["bus_status"] == 4:
                    _require(row["halted"], f"prefetch row {index} reports HLT without halted state")
            if row["code_accept"]:
                _require(row["bus_valid"] and row["bus_status"] == 13 and row["ready"],
                         f"prefetch row {index} code acceptance lacks a ready code bus")
            if row["fetch_request_internal"]:
                _require(row["queue_count"] <= 4,
                         f"prefetch row {index} requested refill above the RTL threshold")
            _require(row["queue_empty_fetch_activity"] == int(
                row["queue_count"] == 0 and not row["halted"] and
                (row["fetch_bus_valid"] or row["fetch_response_valid"] or
                 row["fetch_request_internal"])),
                     f"prefetch row {index} queue/fetch activity classification is inconsistent")
            expected_byte_demand = (
                row["execution_allowed"] and not row["event_active"] and
                not row["event_request"] and not row["event_completed"] and
                not row["raw_retired"] and not row["operand_blocked"] and
                not row["unsupported"] and not row["halted"] and
                row["queue_count"] == 0 and not row["queue_consume_valid"] and
                ((row["micro_active"] and row["executor_byte_ready"]) or
                 (not row["micro_active"] and row["decode_ready"])))
            _require(row["byte_demand"] == int(expected_byte_demand),
                     f"prefetch row {index} effective byte demand is inconsistent")
            _require(row["instruction_wait"] == row["byte_demand"],
                     f"prefetch row {index} instruction wait is not effective byte demand")
            if row["model_code_accept"]:
                _require(row["code_accept"] and not row["restart"],
                         f"prefetch row {index} model accepted a non-accepted/restarted code bus")
                expected_count = 1 if row["bhe_n"] or (row["address"] & 1) else 2
                _require(row["model_pending_count"] == 0,
                         f"prefetch row {index} model admitted a second code transfer")
                _require(row["model_pending_count_after"] == expected_count,
                         f"prefetch row {index} model pending byte count is wrong")
            if row["response_accept"]:
                _require(row["fetch_response_valid"] and row["fetch_response_ready"],
                         f"prefetch row {index} accepted an invisible response")
                _require(row["model_pending_count"] in (1, 2),
                         f"prefetch row {index} accepted a response without pending bytes")
                _require(row["model_pending_count_after"] == 0,
                         f"prefetch row {index} retained a response after acceptance")
                _require(row["response_count"] == row["model_pending_count"],
                         f"prefetch row {index} response count differs from model")
            if row["consume_accept"]:
                _require(row["consume_valid"], f"prefetch row {index} consumed an invalid queue head")
                _require(row["expected_consume"] >= 0,
                         f"prefetch row {index} has no reference byte for a consume")
                _require(row["consume_data"] == row["expected_consume"],
                         f"prefetch row {index} consumed a byte different from the reference")
            else:
                _require(row["expected_consume"] == -1,
                         f"prefetch row {index} published an unused expected byte")
            expected_queue_after = row["model_queue_count"] - row["consume_accept"]
            if row["response_accept"]:
                expected_queue_after += row["response_count"]
            if row["restart"]:
                expected_queue_after = 0
            _require(row["model_queue_count_after"] == expected_queue_after,
                     f"prefetch row {index} reference queue transition is inconsistent")
            expected_pending_after = row["model_pending_count"]
            if row["response_accept"]:
                expected_pending_after = 0
            if row["model_code_accept"]:
                expected_pending_after = 1 if row["bhe_n"] or (row["address"] & 1) else 2
            if row["restart"]:
                expected_pending_after = 0
            _require(row["model_pending_count_after"] == expected_pending_after,
                     f"prefetch row {index} reference pending transition is inconsistent")
            if row["invalidated_pending"]:
                _require(row["restart"], f"prefetch row {index} invalidated bytes without a restart")
            if row["instruction_wait"]:
                _require(row["queue_count"] == 0 and row["execution_allowed"] and
                         not row["halted"] and not row["operand_wait"] and
                         not row["event_active"] and not row["queue_consume_valid"],
                         f"prefetch row {index} misclassified instruction-byte wait")
            if row["data_wait"]:
                _require(row["bus_valid"] and not row["ready"] and row["bus_status"] != 13,
                         f"prefetch row {index} misclassified data wait")

        if previous is not None:
            _require(row["cycle"] == previous["cycle"] + 1,
                     f"prefetch row {index} cycle is not contiguous")
            if row["scenario"] == previous["scenario"] and not row["reset"]:
                _require(row["model_queue_count"] == previous["model_queue_count_after"],
                         f"prefetch row {index} lost the previous reference queue state")
                _require(row["model_pending_count"] == previous["model_pending_count_after"],
                         f"prefetch row {index} lost the previous pending state")
        previous = row
        previous_halted = False if row["reset"] else bool(row["halted"])


def validate_workload(rows: list[dict[str, int]]) -> None:
    """Require the integrated scenarios, not only a final HLT."""
    _require(any(row["queue_count"] == 6 for row in rows), "capture did not reach queue capacity")
    _require(any(row["queue_count"] == 0 for row in rows if not row["reset"]),
             "capture did not observe an empty queue")
    _require(any(row["instruction_wait"] for row in rows), "capture did not observe instruction-byte wait")
    _require(any(row["queue_empty_fetch_activity"] and not row["instruction_wait"] for row in rows),
             "capture lacks queue-empty fetch activity without a byte demand")
    _require(any(row["operand_wait"] for row in rows), "capture did not observe operand wait")
    _require(any(row["data_wait"] for row in rows), "capture did not observe data wait")
    _require(any(row["invalidated_pending"] for row in rows), "capture did not observe stale-stream invalidation")
    scenario4 = [row for row in rows if row["scenario"] == 4]
    _require(scenario4, "capture did not observe scenario 4 HLT resumption workload")
    _require(any(row["halted"] for row in rows), "capture did not reach HLT")
    resume_positions = [
        index for index, row in enumerate(rows)
        if row["scenario"] == 4 and row["hlt_resume"]
    ]
    _require(resume_positions, "capture did not observe HLT resumption in scenario 4")
    resume_position = resume_positions[0]
    scenario4_resume_position = next(
        index for index, row in enumerate(scenario4) if row["hlt_resume"]
    )
    _require(any(row["halted"] for row in scenario4[:scenario4_resume_position]),
             "scenario 4 resumed without a preceding HLT")
    post_resume = scenario4[scenario4_resume_position:]
    _require(any(row["event_active"] and not row["halted"] for row in post_resume),
             "scenario 4 has no active event after HLT resumption")
    _require(any(row["halted"] for row in post_resume),
             "scenario 4 did not reach its second HLT")
    _require(rows[resume_position]["scenario"] == 4,
             "HLT resumption marker is outside scenario 4")
    _require(any(row["response_accept"] for row in rows), "capture did not accept a prefetch response")
    _require(any(row["consume_accept"] for row in rows), "capture did not consume an instruction byte")


def compare_captures(left: Path, right: Path) -> tuple[list[dict[str, int]], list[dict[str, int]]]:
    left_rows = read_capture(left)
    right_rows = read_capture(right)
    if left_rows != right_rows:
        for index, (left_row, right_row) in enumerate(zip(left_rows, right_rows)):
            if left_row != right_row:
                raise ValueError(f"prefetch captures diverge at normalized row {index}")
        raise ValueError("prefetch captures have different row counts")
    return left_rows, right_rows


def capture_input_paths_9d() -> tuple[list[Path], list[Path]]:
    compiled, support = capture_input_paths()
    support = list(support)
    support.extend([
        ROOT / "tools/capture_prefetch_fidelity.py",
        ROOT / "sim/unit/spk286_prefetch_fidelity_tb.sv",
    ])
    return compiled, sorted(set(support))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", choices=("verilator", "iverilog"), required=True)
    parser.add_argument("--build-dir", type=Path,
                        default=Path(os.environ.get("SPK286_BUILD_DIR", ROOT / "build")))
    args = parser.parse_args()

    if git_status():
        raise RuntimeError("prefetch capture requires a clean Git tree before compilation")
    revision = run(["git", "rev-parse", "HEAD"])
    branch = run(["git", "branch", "--show-current"])
    compiled_inputs, support_inputs = capture_input_paths_9d()
    input_hashes_before = hash_paths(compiled_inputs + support_inputs)
    build_dir = args.build_dir if args.build_dir.is_absolute() else ROOT / args.build_dir
    timing_dir = build_dir / "timing"
    timing_dir.mkdir(parents=True, exist_ok=True)
    trace_path = timing_dir / "spk286_prefetch_fidelity.csv"
    manifest_path = timing_dir / "spk286_prefetch_fidelity.json"

    env = os.environ.copy()
    env["SPK286_BUILD_DIR"] = str(build_dir)
    run(["bash", "scripts/test_units.sh", args.simulator, "spk286_prefetch_fidelity"], env=env)
    rows = read_capture(trace_path)
    validate_workload(rows)
    if git_status() or run(["git", "rev-parse", "HEAD"]) != revision:
        raise RuntimeError("Git revision changed while prefetch capture was running")
    if hash_paths(compiled_inputs + support_inputs) != input_hashes_before:
        raise RuntimeError("prefetch capture inputs changed while running")
    version_command = [args.simulator, "-V"] if args.simulator == "iverilog" else [args.simulator, "--version"]
    simulator_version = run(version_command).splitlines()[0]
    manifest = {
        "schema_version": 1,
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
        "workload": "linear refill/data traffic, odd redirect during READY wait, starvation and HLT/NMI resume",
        "trace": {
            "path": manifest_relative(trace_path, manifest_path),
            "path_base": "manifest_directory",
            "repository_path": repository_relative(trace_path),
            "sha256": sha256_file(trace_path),
            "records": len(rows),
        },
        "input_hashes": dict(input_hashes_before),
        "summary": {
            "scenarios": sorted({row["scenario"] for row in rows}),
            "records": len(rows),
            "max_queue_count": max(row["queue_count"] for row in rows),
            "instruction_wait_samples": sum(row["instruction_wait"] for row in rows),
            "queue_activity_without_demand_samples": sum(
                row["queue_empty_fetch_activity"] and not row["instruction_wait"] for row in rows
            ),
            "operand_wait_samples": sum(row["operand_wait"] for row in rows),
            "data_wait_samples": sum(row["data_wait"] for row in rows),
            "stale_invalidations": sum(row["invalidated_pending"] for row in rows),
            "hlt_resume_samples": sum(row["hlt_resume"] for row in rows),
            "halted": any(row["halted"] for row in rows),
        },
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        "PREFETCH FIDELITY MANIFEST PASS: "
        f"{manifest_path} records={len(rows)} sha256={manifest['trace']['sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
