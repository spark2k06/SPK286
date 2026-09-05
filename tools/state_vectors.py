"""Initialize the RTL datapath and verify its first fetch from SingleStep-shaped data.

This deliberately does not execute or compare instructions. A normal CS reload
is used, matching the corpus's entry-after-a-jump convention, not reset CS state.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import subprocess

from tools.singlestep import SingleStepCase, load_source


GPRS = ("ax", "cx", "dx", "bx", "sp", "bp", "si", "di")
SEGMENTS = ("es", "cs", "ss", "ds")
DEFAULT_REGS = dict.fromkeys(GPRS + SEGMENTS, 0) | {"cs": 0xF000, "ip": 0xFFF0, "flags": 2}


@dataclass(frozen=True)
class InitialState:
    regs: dict[str, int]
    ram: dict[int, int]


def checked(value: object, maximum: int, label: str) -> int:
    if type(value) is not int or not 0 <= value <= maximum:
        raise ValueError(f"invalid {label}: {value!r}")
    return value


def prepare_initial(case: SingleStepCase) -> InitialState:
    regs = DEFAULT_REGS.copy()
    if case.initial.get("queue"):
        raise ValueError("pre-existing queue state is not supported")
    if set(case.initial) - {"regs", "ram", "queue"}:
        raise ValueError("only ordinary real-mode initial state is supported")
    for name, value in case.initial.get("regs", {}).items():
        if name not in regs:
            raise ValueError(f"unsupported register: {name}")
        regs[name] = checked(value, 0xFFFF, name)
    if regs["flags"] & 0x8028 or not regs["flags"] & 2:
        raise ValueError("FLAGS must use the canonical 286 storage representation")
    ram = {}
    for address, value in case.initial.get("ram", []):
        address = checked(address, 0xFFFFFF, "RAM address")
        value = checked(value, 0xFF, "RAM byte")
        if address in ram and ram[address] != value:
            raise ValueError(f"conflicting RAM initialization at {address:06x}")
        ram[address] = value
    state = InitialState(regs, ram)
    expected_snapshot(state)  # Require explicitly supplied first-fetch bytes.
    return state


def expected_snapshot(state: InitialState) -> dict:
    address = state.regs["cs"] * 16 + state.regs["ip"]
    count = 1 if address % 2 or state.regs["ip"] == 0xFFFF else 2
    try:
        data = sum(state.ram[address + byte] << (8 * byte) for byte in range(count))
    except KeyError as error:
        raise ValueError(f"first-fetch byte is not initialized: {error.args[0]:06x}") from error
    return {
        "regs": state.regs,
        "bases": [state.regs[name] * 16 for name in SEGMENTS],
        "limits": [0xFFFF] * 4,
        "access": [0x93] * 4,
        "fetch_address": address,
        "fetch_ip": state.regs["ip"],
        "fetch_count": count,
        "fetch_data": data,
        "instructions_executed": 0,
    }


def serialize_initial(state: InitialState) -> str:
    lines = [f"REG {name} {value}" for name, value in state.regs.items()]
    lines += [f"RAM {address} {value}" for address, value in sorted(state.ram.items())]
    return "\n".join(lines) + "\nEND\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("tests/fixtures/singlestep_sample.json"))
    parser.add_argument("--build-dir", type=Path, default=Path(os.environ.get("SPK286_BUILD_DIR", "build")))
    args = parser.parse_args()
    cases = load_source(args.source)
    if not cases:
        raise ValueError("no state vectors selected")
    output = args.build_dir / "state-vectors" / args.source.stem
    output.mkdir(parents=True, exist_ok=True)
    for ordinal, case in enumerate(cases):
        state = prepare_initial(case)
        vector = output / f"case-{ordinal}.txt"
        vector.write_text(serialize_initial(state), encoding="ascii")
        expected = expected_snapshot(state)
        (output / f"case-{ordinal}-expected.json").write_text(json.dumps(expected, indent=2), encoding="utf-8")
        result = subprocess.run(
            [str((args.build_dir / "verilator/obj_dir/spk286_smoke").resolve()), "--state-vector", str(vector.resolve())],
            capture_output=True, text=True, timeout=20, check=False,
        )
        (output / f"case-{ordinal}-actual.json").write_text(result.stdout, encoding="utf-8")
        (output / f"case-{ordinal}-stderr.txt").write_text(result.stderr, encoding="utf-8")
        if result.returncode:
            raise RuntimeError(f"case {case.index}: RTL driver exited {result.returncode}; inspect {output}: {result.stderr}")
        actual = json.loads(result.stdout)
        if actual != expected:
            raise AssertionError(f"case {case.index} ({case.name}): state/fetch mismatch; inspect {output}")
    print(f"STATE_VECTOR PASS: {len(cases)} initialization/fetch cases; instructions_executed=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
