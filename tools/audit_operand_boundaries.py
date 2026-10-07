"""Prove operand/BIU boundary assertions reject isolated RTL faults with Icarus.

Mutants are compiled only in the ignored build directory. Production RTL,
microcode and hardware vectors are never edited. This supplements, rather
than replaces, the dual-simulator positive suite and full SingleStep gate.
"""

import argparse
import hashlib
import os
from pathlib import Path
import subprocess


from tools.rtl_sources import ordered_rtl_sources

ROOT = Path(__file__).resolve().parents[1]
PROBES = (
    ("code-owner", "spk286_biu", "spk286_biu",
     "owner_valid_q ? owner_q : (ack_active_q ? 2'd2 : (data_active_q ? 2'd1 : 2'd0))",
     "(ack_active_q ? 2'd2 : (data_active_q ? 2'd1 : 2'd0))",
     "data cannot preempt active code"),
    ("cancel-ready", "spk286_biu", "spk286_biu",
     "data_response_valid <= !canceled_q && !cancel_data;",
     "data_response_valid <= !canceled_q;",
     "code resumes after canceled A20-crossing word"),
    ("duplicate-request", "spk286_operand", "spk286_operand_service",
     "allowed && is_memory && !pending_q && within_limit",
     "allowed && is_memory && within_limit",
     "pending operation cannot resubmit"),
    ("word-limit-inclusive", "spk286_operand", "spk286_operand_service",
     "(offset < segment_limit ||",
     "(offset <= segment_limit ||",
     "invalid whole word rejected before acceptance"),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path,
                        default=Path(os.environ.get("SPK286_BUILD_DIR", "build")))
    args = parser.parse_args()
    subprocess.run(["python3", "-m", "tools.microcode.compile_microcode", "--check"],
                   cwd=ROOT, check=True)
    sources = ordered_rtl_sources(ROOT)
    originals = {p: p.read_bytes() for p in sources}
    output = args.build_dir.resolve() / "operand-boundary-audit"
    output.mkdir(parents=True, exist_ok=True)
    (output / "source.sha256").write_text("".join(
        f"{hashlib.sha256(data).hexdigest()}  {path.relative_to(ROOT).as_posix()}\n"
        for path, data in originals.items()), encoding="utf-8")

    def execute(name, bench, replacement=None, reason=None):
        directory = output / name
        directory.mkdir(parents=True, exist_ok=True)
        inputs = list(sources)
        if replacement:
            module, old, new = replacement
            path = ROOT / "rtl" / (module + ".sv")
            source = originals[path].decode("utf-8")
            if source.count(old) != 1:
                raise RuntimeError(f"{name}: mutation anchor must occur exactly once")
            mutant = directory / path.name
            mutant.write_text(source.replace(old, new), encoding="utf-8")
            inputs[inputs.index(path)] = mutant
        binary = directory / "test.vvp"
        command = ["iverilog", "-g2012", "-Wall", "-Irtl", "-Isim/unit", "-s", bench + "_tb",
                   "-o", str(binary), *map(str, inputs), str(ROOT / "sim/unit" / (bench + "_tb.sv"))]
        build = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        (directory / "build.log").write_text(build.stdout + build.stderr, encoding="utf-8")
        if build.returncode:
            raise RuntimeError(f"{name}: compile failed; this is not a rejected functional mutant")
        result = subprocess.run(["vvp", str(binary)], cwd=ROOT, capture_output=True, text=True, timeout=600)
        (directory / "run.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        if reason:
            if result.returncode == 0 or reason not in result.stdout + result.stderr:
                raise RuntimeError(f"{name}: expected assertion did not reject mutant")
        elif result.returncode != 0 or "PASS:" not in result.stdout:
            raise RuntimeError(f"{name}: pristine bench failed")
        print(f"BOUNDARY_PROBE {name}: {'rejected' if reason else 'passed'} status={result.returncode}")

    for bench in sorted({p[2] for p in PROBES}):
        execute("pristine-" + bench, bench)
    for name, module, bench, old, new, reason in PROBES:
        execute(name, bench, (module, old, new), reason)
    if any(path.read_bytes() != data for path, data in originals.items()):
        raise RuntimeError("production sources changed during boundary audit")
    print("OPERAND_BOUNDARY_AUDIT PASS: 4 rejected RTL mutants; 2 pristine benches; source bytes unchanged")


if __name__ == "__main__":
    main()
