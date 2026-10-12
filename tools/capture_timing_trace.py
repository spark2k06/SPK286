# SPDX-License-Identifier: MIT
"""Create and validate a reproducible timing observation capture."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TRACE_COLUMNS = (
    "schema_version", "policy", "reset", "trace_valid", "trace_cycle",
    "phase", "address", "status", "data", "lane_mask", "write", "owner",
    "lock", "hold", "hlda", "ready", "queue_count", "cpu_cycles",
    "biu_busy_cycles", "accepted_transfers", "ready_wait_cycles",
    "prefetch_requests", "prefetch_responses", "queue_consumes",
    "queue_empty_cycles", "redirects", "cancels", "operand_wait_cycles",
    "event_requests", "event_completes", "compatibility_delay_cycles",
    "halted",
)
BOOLEAN_COLUMNS = {
    "reset", "trace_valid", "write", "lock", "hold", "hlda", "ready", "halted"
}
COUNTER_COLUMNS = {
    "cpu_cycles", "biu_busy_cycles", "accepted_transfers", "ready_wait_cycles",
    "prefetch_requests", "prefetch_responses", "queue_consumes",
    "queue_empty_cycles", "redirects", "cancels", "operand_wait_cycles",
    "event_requests", "event_completes", "compatibility_delay_cycles",
}
EVENT_COUNTER_COLUMNS = {
    "prefetch_requests", "prefetch_responses", "queue_consumes",
    "queue_empty_cycles", "redirects", "cancels", "operand_wait_cycles",
    "event_requests", "event_completes",
}
BUS_IDENTITY_COLUMNS = (
    "address", "status", "lane_mask", "write", "owner",
)
UINT64_MAX = (1 << 64) - 1
RANGES = {
    "schema_version": (1, 1), "policy": (0, 0), "phase": (0, 2),
    "address": (0, 0xFFFFFF), "status": (0, 0xF), "data": (0, 0xFFFF),
    "lane_mask": (0, 3), "owner": (0, 3), "queue_count": (0, 6),
}


def run(command: list[str], *, env: dict[str, str] | None = None) -> str:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return completed.stdout.strip()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_status() -> str:
    return run(["git", "status", "--porcelain=v1", "--untracked-files=all"])


def repository_relative(path: Path) -> str | None:
    try:
        return path.resolve().relative_to(ROOT.resolve()).as_posix()
    except ValueError:
        return None


def manifest_relative(path: Path, manifest_path: Path) -> str:
    return Path(os.path.relpath(path.resolve(), manifest_path.parent.resolve())).as_posix()


def capture_input_paths() -> tuple[list[Path], list[Path]]:
    """Return the exact RTL inputs and support files used by the capture."""
    generated = [
        ROOT / "microcode/generated/spk286_microcode_pkg.sv",
        ROOT / "microcode/generated/spk286_microcode_rom.sv",
    ]
    package_files = [ROOT / "rtl/spk286_protected_pkg.sv", ROOT / "rtl/spk286_tss_pkg.sv"]
    rtl_files = [
        path for path in sorted((ROOT / "rtl").glob("*.sv"))
        if path not in package_files
    ]
    compiled = generated + package_files + rtl_files
    support = [
        ROOT / "scripts/rtl_sources.sh",
        ROOT / "scripts/test_units.sh",
        ROOT / "tools/capture_timing_trace.py",
        ROOT / "sim/unit/spk286_timing_capture_tb.sv",
        ROOT / "sim/unit/spk286_signals.svh",
        ROOT / "tools/microcode/compile_microcode.py",
    ]
    support.extend(sorted((ROOT / "microcode").rglob("*.mc")))
    return compiled, support


def hash_paths(paths: list[Path]) -> dict[str, str]:
    missing = [path for path in paths if not path.is_file()]
    if missing:
        raise RuntimeError(f"capture input is missing: {missing[0]}")
    return {path.relative_to(ROOT).as_posix(): sha256_file(path) for path in paths}


def read_trace(path: Path) -> list[dict[str, int]]:
    """Read a CSV and reject malformed rows before any summary is published."""
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.reader(stream)
        try:
            header = next(reader)
        except StopIteration as exc:
            raise ValueError("timing capture is empty") from exc
        expected = list(TRACE_COLUMNS)
        if header != expected:
            raise ValueError(
                "timing capture header mismatch: "
                f"expected {len(expected)} ordered columns, got {len(header)}"
            )
        rows: list[dict[str, int]] = []
        for line_number, fields in enumerate(reader, start=2):
            if len(fields) != len(expected):
                raise ValueError(
                    f"timing capture row {line_number} has {len(fields)} fields; "
                    f"expected {len(expected)}"
                )
            parsed: dict[str, int] = {}
            for name, value in zip(expected, fields):
                try:
                    parsed[name] = int(value, 10)
                except ValueError as exc:
                    raise ValueError(
                        f"timing capture row {line_number} field {name!r} is not an integer"
                    ) from exc
            rows.append(parsed)
    validate_trace_rows(rows)
    return rows


def validate_trace_rows(rows: list[dict[str, int]]) -> None:
    """Validate the schema, domains, bus phase and counter relationships."""
    if not rows:
        raise ValueError("timing capture contains no data rows")
    expected = set(TRACE_COLUMNS)
    previous: dict[str, int] | None = None
    for index, row in enumerate(rows):
        missing = expected - set(row)
        extra = set(row) - expected
        if missing or extra:
            raise ValueError(f"timing row {index} fields differ: missing={missing} extra={extra}")
        for name in BOOLEAN_COLUMNS:
            if row[name] not in (0, 1):
                raise ValueError(f"timing row {index} field {name} is not boolean")
        for name, (low, high) in RANGES.items():
            if not low <= row[name] <= high:
                raise ValueError(f"timing row {index} field {name} is outside [{low},{high}]")
        for name in COUNTER_COLUMNS | {"trace_cycle"}:
            if row[name] < 0:
                raise ValueError(f"timing row {index} field {name} is negative")
            if row[name] > UINT64_MAX:
                raise ValueError(f"timing row {index} field {name} exceeds 64 bits")
        if row["reset"] != 0 or row["trace_valid"] != 1:
            raise ValueError("current trace schema only publishes valid non-reset samples")
        if row["cpu_cycles"] != row["trace_cycle"]:
            raise ValueError(f"timing row {index} CPU and trace cycle differ")
        if row["phase"] == 0:
            if (row["status"], row["owner"], row["lane_mask"], row["address"], row["write"], row["data"]) != (15, 0, 0, 0, 0, 0):
                raise ValueError(f"timing row {index} idle bus fields are incoherent")
        else:
            if row["status"] == 15 or row["owner"] == 0 or row["lane_mask"] == 0:
                raise ValueError(f"timing row {index} active bus fields are incoherent")
            if row["ready"] != int(row["phase"] == 2):
                raise ValueError(f"timing row {index} phase and READY disagree")
            expected_owner = 3 if row["status"] == 0 else 1 if row["status"] == 0xD else 2
            if row["owner"] != expected_owner:
                raise ValueError(
                    f"timing row {index} status {row['status']} has owner {row['owner']}; "
                    f"expected {expected_owner}"
                )
            if row["address"] & 1:
                if row["lane_mask"] != 2:
                    raise ValueError(
                        f"timing row {index} odd address requires high-byte lane mask 2"
                    )
            elif row["lane_mask"] not in (1, 3):
                raise ValueError(
                    f"timing row {index} even address requires lane mask 1 or 3"
                )
        if row["policy"] == 0 and row["compatibility_delay_cycles"] != 0:
            raise ValueError("normalized policy cannot report compatibility delay cycles")
        for name in COUNTER_COLUMNS - {"cpu_cycles"}:
            if row[name] > row["cpu_cycles"]:
                raise ValueError(
                    f"timing row {index} counter {name} exceeds elapsed CPU cycles"
                )
        if row["biu_busy_cycles"] != row["accepted_transfers"] + row["ready_wait_cycles"]:
            raise ValueError(f"timing row {index} BIU busy counter is inconsistent")
        if previous is not None:
            if row["trace_cycle"] != previous["trace_cycle"] + 1:
                raise ValueError(f"timing row {index} trace cycle is not contiguous")
            for name in COUNTER_COLUMNS:
                if row[name] < previous[name]:
                    raise ValueError(f"timing row {index} counter {name} goes backwards")
            for name in EVENT_COUNTER_COLUMNS:
                delta = row[name] - previous[name]
                if delta not in (0, 1):
                    raise ValueError(
                        f"timing row {index} counter {name} increments by {delta}; "
                        "expected 0 or 1"
                    )
            expected_busy = int(previous["phase"] != 0)
            expected_accept = int(previous["phase"] == 2)
            expected_wait = int(previous["phase"] == 1)
            if row["biu_busy_cycles"] - previous["biu_busy_cycles"] != expected_busy:
                raise ValueError(f"timing row {index} BIU busy delta is inconsistent")
            if row["accepted_transfers"] - previous["accepted_transfers"] != expected_accept:
                raise ValueError(f"timing row {index} accepted-transfer delta is inconsistent")
            if row["ready_wait_cycles"] - previous["ready_wait_cycles"] != expected_wait:
                raise ValueError(f"timing row {index} READY-wait delta is inconsistent")
            if previous["phase"] == 1 and row["phase"] == 0:
                raise ValueError(
                    f"timing row {index} READY-wait transaction disappears before completion"
                )
            if previous["phase"] == 1 and row["phase"] in (1, 2):
                for name in BUS_IDENTITY_COLUMNS:
                    if row[name] != previous[name]:
                        raise ValueError(
                            f"timing row {index} changes bus transaction {name} "
                            "while waiting for READY"
                        )
                if previous["write"] and row["data"] != previous["data"]:
                    raise ValueError(
                        f"timing row {index} changes write data while waiting for READY"
                    )
        previous = row


def validate_capture_workload(rows: list[dict[str, int]]) -> None:
    """Check expectations specific to the deterministic capture workload."""
    last = rows[-1]
    if not last["halted"]:
        raise ValueError("capture workload did not reach HLT")
    for name in ("accepted_transfers", "ready_wait_cycles", "prefetch_requests", "queue_consumes"):
        if last[name] <= 0:
            raise ValueError(f"capture workload did not exercise {name}")
    if not any(row["lock"] for row in rows):
        raise ValueError("capture workload did not observe implicit LOCK")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--simulator", choices=("verilator", "iverilog"), default="verilator",
        help="simulator used for the persistent capture (default: verilator)",
    )
    parser.add_argument(
        "--build-dir", type=Path,
        default=Path(os.environ.get("SPK286_BUILD_DIR", ROOT / "build")),
        help="build/output directory (default: SPK286_BUILD_DIR or build)",
    )
    args = parser.parse_args()

    if git_status():
        raise RuntimeError("timing capture requires a clean Git tree before compilation")
    revision = run(["git", "rev-parse", "HEAD"])
    branch = run(["git", "branch", "--show-current"])
    compiled_inputs, support_inputs = capture_input_paths()
    input_hashes_before = hash_paths(compiled_inputs + support_inputs)

    build_dir = args.build_dir if args.build_dir.is_absolute() else ROOT / args.build_dir
    timing_dir = build_dir / "timing"
    timing_dir.mkdir(parents=True, exist_ok=True)
    trace_path = timing_dir / "spk286_timing_capture.csv"
    manifest_path = timing_dir / "spk286_timing_capture.json"

    env = os.environ.copy()
    env["SPK286_BUILD_DIR"] = str(build_dir)
    run(["bash", "scripts/test_units.sh", args.simulator, "spk286_timing_capture"], env=env)

    rows = read_trace(trace_path)
    validate_capture_workload(rows)
    if git_status():
        raise RuntimeError("Git tree changed while timing capture was running")
    if run(["git", "rev-parse", "HEAD"]) != revision:
        raise RuntimeError("HEAD changed while timing capture was running")
    input_hashes_after = hash_paths(compiled_inputs + support_inputs)
    if input_hashes_after != input_hashes_before:
        raise RuntimeError("capture inputs changed while timing capture was running")

    version_command = [args.simulator, "-V"] if args.simulator == "iverilog" else [args.simulator, "--version"]
    simulator_version = run(version_command).splitlines()[0]
    trace_repo_path = repository_relative(trace_path)
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
        "workload": "MOV AX,1234; XCHG [0200],AX; HLT with deterministic READY waits",
        "reset_context": {
            "reset_cycles": 1,
            "cs_selector": "0000",
            "cs_base": "000000",
            "initial_ip": "0100",
        },
        "trace": {
            "path": manifest_relative(trace_path, manifest_path),
            "path_base": "manifest_directory",
            "repository_path": trace_repo_path,
            "sha256": sha256_file(trace_path),
            "records": len(rows),
        },
        "input_hashes": dict(input_hashes_before),
        "summary": {
            "first_cycle": rows[0]["trace_cycle"],
            "last_cycle": rows[-1]["trace_cycle"],
            "accepted_transfers": rows[-1]["accepted_transfers"],
            "ready_wait_cycles": rows[-1]["ready_wait_cycles"],
            "prefetch_requests": rows[-1]["prefetch_requests"],
            "queue_consumes": rows[-1]["queue_consumes"],
            "halted": bool(rows[-1]["halted"]),
        },
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        "TIMING CAPTURE MANIFEST PASS: "
        f"{manifest_path} records={len(rows)} sha256={manifest['trace']['sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
