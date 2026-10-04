#!/usr/bin/env python3
"""CPU-only deterministic generation, strict elaboration and schedule oracle.

No board RTL, private evidence bundle, FPGA tool or external corpus is required.
All simulator output is written below --output. Functional CPU acceptance is
separate; the schedule oracle cannot certify the host's temporal bus contract.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from build_p06_profile_cpu import ROOT, build, sha, load_selected_contract, SELECTED_CONTRACT

def run(command, log):
    result = subprocess.run([str(v) for v in command], cwd=ROOT, capture_output=True,
                            text=True, timeout=600)
    log.write_text(result.stdout + result.stderr, newline="\n")
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}")
    return result.stdout + result.stderr

def check(out):
    out = Path(out).resolve()
    if not out.is_relative_to((ROOT / "build").resolve()):
        raise ValueError("Output must stay below the standalone build directory")
    out.mkdir(parents=True, exist_ok=True)
    selected_contract = load_selected_contract()
    contract = json.loads((ROOT / selected_contract["baseline_contract_path"]).read_text())
    selected = build(out / "generated")
    repeated = build(out / "repeated")
    for name, path in selected.items():
        if path.read_bytes() != repeated[name].read_bytes():
            raise RuntimeError(f"Nondeterministic generated source: {name}")
        if sha(path) != selected_contract["expected_profiled_sha256"][name]:
            raise RuntimeError(f"Published profile source identity failed: {name}")
        if path.read_bytes() != (ROOT / "rtl/timed" / name).read_bytes():
            raise RuntimeError(f"Installed generated source is stale: {name}")
    if (out / "generated/generation.json").read_bytes() != (out / "repeated/generation.json").read_bytes():
        raise RuntimeError("Nondeterministic generation manifest")
    paths = [ROOT / name for name in contract["ordered_rtl_sources"]
             if Path(name).name not in ("spk286.sv", "spk286_events.sv")]
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
    signal_fixture = ROOT / "sim/unit/spk286_signals.svh"
    if sha(signal_fixture) != selected_contract["probe_fixture_sha256"][signal_fixture.relative_to(ROOT).as_posix()]:
        raise RuntimeError("Probe fixture source changed")
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
    metadata_test = ROOT / "scripts/test_instruction_timing.py"
    metadata_bench = ROOT / "sim/unit/spk286_instruction_timing_tb.sv"
    run([sys.executable, "-B", metadata_test, "--output", out / "metadata"],
        out / "metadata.log")
    metadata_receipt = json.loads((out / "metadata/receipt.json").read_text())
    if metadata_receipt["status"] != "PASS" or metadata_receipt["coverage"]["cases"] != 43878:
        raise RuntimeError("Full independent metadata oracle receipt mismatch")
    sources = [ROOT / "scripts/build_p06_profile_cpu.py", Path(__file__).resolve(),
               ROOT / "tools/profile_cpu_baseline.json", ROOT / SELECTED_CONTRACT, timing, schedule, bench,
               prefix_bench, signal_fixture, reset_bench, metadata_test, metadata_bench]
    receipt = {
        "status": "CPU_ONLY_PROFILE_FOCUSED_PASS_NOT_HOST_ACCEPTANCE",
        "baseline_sha256": contract["baseline_sha256"],
        "selected_contract_sha256": sha(ROOT / SELECTED_CONTRACT),
        "functional_updates_sha256": selected_contract["functional_updates_sha256"],
        "selected_functional_sha256": {name: sha(ROOT / name) for name in contract["ordered_rtl_sources"]},
        "sources_sha256": {p.relative_to(ROOT).as_posix(): sha(p) for p in sources},
        "generated_sha256": {name: sha(path) for name, path in selected.items()},
        "schedule_oracle_checks_per_simulator": 45,
        "passive_full_top_prefix_cases_per_simulator": 8,
        "reset_fetch_smoke_mode_markers": reset_markers,
        "metadata_receipt_sha256": sha(out / "metadata/receipt.json"),
        "independent_metadata_cases_per_simulator": 43878,
        "artifact_sha256": {p.relative_to(out).as_posix(): sha(p) for p in sorted(out.glob("*.log"))},
        "scope": "Published generated source identity and deterministic manifest; strict full-CPU lint; independent schedule, metadata and passive full-TOP prefix budget probes in Icarus and Verilator, unchanged reset/fetch assertions in two mode settings in Icarus. No board bus, frequency/OSD, external SingleStep CPU corpus, Quartus, OS or host acceptance.",
    }
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", newline="\n")
    print(receipt["status"])
    return receipt

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    check(parser.parse_args().output)
