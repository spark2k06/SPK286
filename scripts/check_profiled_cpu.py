#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check the profiled timing variant: freshness, strict lint and dual-simulator oracles.

No board RTL, FPGA tool or external corpus is required. All simulator output
is written below --output. Functional CPU acceptance is separate; the schedule
oracle cannot certify the host's temporal bus contract.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from build_profiled_cpu import ROOT, OUTPUT, build, sha

sys.path.insert(0, str(ROOT))
from tools.rtl_sources import ordered_rtl_sources  # noqa: E402

def run(command, log):
    result = subprocess.run([str(v) for v in command], cwd=ROOT, capture_output=True,
                            text=True, timeout=600)
    log.write_text(result.stdout + result.stderr, newline="\n")
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}")
    return result.stdout + result.stderr

def check(out):
    out = Path(out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    selected = build(out / "generated")
    repeated = build(out / "repeated")
    for name, path in selected.items():
        if path.read_bytes() != repeated[name].read_bytes():
            raise RuntimeError(f"Nondeterministic generated source: {name}")
        if path.read_bytes() != (OUTPUT / name).read_bytes():
            raise RuntimeError(f"Installed generated source is stale: {name}; run make profiled")
    paths = [path for path in ordered_rtl_sources(ROOT)
             if path.name not in ("spk286.sv", "spk286_events.sv")]
    timing = ROOT / "rtl/timing/spk286_instruction_timing.sv"
    schedule = ROOT / "rtl/timing/spk286_instruction_schedule.sv"
    bench = ROOT / "sim/unit/spk286_instruction_schedule_tb.sv"
    paths += [timing, schedule, *selected.values()]
    run(["verilator", "--lint-only", "--Wall", "--top-module", "spk286_profiled",
         "-I" + str(ROOT / "rtl"), *paths], out / "lint.log")
    binary = out / "schedule.vvp"
    run(["iverilog", "-g2012", "-s", "spk286_instruction_schedule_tb", "-o", binary,
         schedule, bench], out / "iverilog-build.log")
    first = run(["vvp", binary], out / "iverilog-run.log")
    obj = out / "verilator"
    run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal",
         "--top-module", "spk286_instruction_schedule_tb", "--Mdir", obj,
         schedule, bench], out / "verilator-build.log")
    second = run([obj / "Vspk286_instruction_schedule_tb"], out / "verilator-run.log")
    count1 = re.findall(r"^PROFILE_SCHEDULE_PASS checks(\d+)$", first, re.MULTILINE)
    count2 = re.findall(r"^PROFILE_SCHEDULE_PASS checks(\d+)$", second, re.MULTILINE)
    if count1 != ["45"] or count2 != count1:
        raise RuntimeError("Independent dual schedule oracle count/marker mismatch")
    prefix_bench = ROOT / "sim/unit/spk286_profile_prefix_tb.sv"
    prefix_include = "-I" + str(ROOT / "sim/unit")
    prefix_binary = out / "prefix.vvp"
    run(["iverilog", "-g2012", "-s", "spk286_profile_prefix_tb", prefix_include,
         "-o", prefix_binary, *paths, prefix_bench], out / "prefix-iverilog-build.log")
    prefix_first = run(["vvp", prefix_binary], out / "prefix-iverilog-run.log")
    prefix_obj = out / "prefix-verilator"
    run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal", prefix_include,
         "--top-module", "spk286_profile_prefix_tb", "--Mdir", prefix_obj,
         *paths, prefix_bench], out / "prefix-verilator-build.log")
    prefix_second = run([prefix_obj / "Vspk286_profile_prefix_tb"], out / "prefix-verilator-run.log")
    marker1 = re.findall(r"^PROFILE_PREFIX_PASS cases8 checks\d+$", prefix_first, re.MULTILINE)
    marker2 = re.findall(r"^PROFILE_PREFIX_PASS cases8 checks\d+$", prefix_second, re.MULTILINE)
    cases1 = re.findall(r"^PROFILE_PREFIX_CASE.*$", prefix_first, re.MULTILINE)
    cases2 = re.findall(r"^PROFILE_PREFIX_CASE.*$", prefix_second, re.MULTILINE)
    if len(marker1) != 1 or marker1 != marker2 or len(cases1) != 8 or cases1 != cases2:
        raise RuntimeError("Passive full-TOP prefix aggregation oracle mismatch")
    reset_bench = ROOT / "sim/unit/spk286_profile_reset_tb.sv"
    reset_markers = []
    for mode in (0, 1):
        reset_binary = out / f"reset-{mode}.vvp"
        run(["iverilog", "-g2012", "-s", "spk286_profile_reset_tb", prefix_include,
             "-P", f"spk286_profile_reset_tb.HISTORICAL={mode}", "-o", reset_binary,
             *paths, reset_bench], out / f"reset-{mode}-build.log")
        reset_log = run(["vvp", reset_binary], out / f"reset-{mode}-run.log")
        marker = re.findall(r"^RESET_SMOKE PASS.*$", reset_log, re.MULTILINE)
        if len(marker) != 1:
            raise RuntimeError(f"Unchanged reset/fetch oracle failed mode{mode}")
        reset_markers.append(marker[0])
    if reset_markers[0] != reset_markers[1]:
        raise RuntimeError("Reset/fetch observable mode mismatch")
    metadata_test = ROOT / "scripts/check_instruction_timing.py"
    shutil.rmtree(out / "metadata", ignore_errors=True)
    run([sys.executable, "-B", metadata_test, "--output", out / "metadata"],
        out / "metadata.log")
    metadata_receipt = json.loads((out / "metadata/receipt.json").read_text())
    if metadata_receipt["status"] != "PASS" or metadata_receipt["coverage"]["cases"] != 43878:
        raise RuntimeError("Full independent metadata oracle receipt mismatch")
    receipt = {
        "status": "PROFILED_CPU_PASS",
        "generated_sha256": {name: sha(path) for name, path in selected.items()},
        "schedule_oracle_checks_per_simulator": 45,
        "passive_full_top_prefix_cases_per_simulator": 8,
        "reset_fetch_smoke_mode_markers": reset_markers,
        "independent_metadata_cases_per_simulator": 43878,
    }
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", newline="\n")
    print(receipt["status"])
    return receipt

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    build_dir = Path(os.environ.get("SPK286_BUILD_DIR", ROOT / "build"))
    parser.add_argument("--output", type=Path, default=build_dir / "profiled-check")
    check(parser.parse_args().output)
