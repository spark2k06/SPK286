#!/usr/bin/env python3
"""SingleStep data selection smoke tool.

This command validates and selects external SingleStep data. It deliberately
does not claim to execute instructions until a CPU adapter exists.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import os
import sys

from singlestep import SingleStepFormatError, load_source


def _default_fixture() -> Path:
    return Path(__file__).resolve().parents[1] / "tests" / "fixtures" / "singlestep_sample.json"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="SingleStep .json, .jsonl, or .moo file")
    parser.add_argument("--smoke", action="store_true", help="validate the checked-in sample vector")
    parser.add_argument("--limit", type=int, default=0, help="maximum selected cases")
    parser.add_argument("--test-id", type=int, help="select one case index")
    parser.add_argument("--opcode", help="filter case names by this text")
    parser.add_argument("--json", action="store_true", help="emit a machine-readable summary")
    args = parser.parse_args(argv)

    source = args.source
    if source is None and args.smoke:
        source = _default_fixture()
    if source is None:
        configured = os.environ.get("SPK286_SINGLESTEP_PATH")
        if configured:
            source = Path(configured)
    if source is None:
        parser.error("provide --source, --smoke, or SPK286_SINGLESTEP_PATH")

    try:
        cases = load_source(source)
    except (OSError, json.JSONDecodeError, SingleStepFormatError) as error:
        print(f"SINGLESTEP DATA FAIL: {error}", file=sys.stderr)
        return 1

    selected = cases
    if args.test_id is not None:
        selected = tuple(case for case in selected if case.index == args.test_id)
    if args.opcode:
        selected = tuple(case for case in selected if args.opcode.lower() in case.name.lower())
    if args.limit:
        if args.limit < 0:
            parser.error("--limit must be non-negative")
        selected = selected[: args.limit]

    summary = {
        "source": str(source),
        "parsed": len(cases),
        "selected": len(selected),
        "indices": [case.index for case in selected],
        "execution": "not performed by this tool",
    }
    if args.json:
        print(json.dumps(summary, sort_keys=True))
    else:
        print(
            f"SINGLESTEP DATA PASS parsed={summary['parsed']} selected={summary['selected']} "
            "execution=deferred"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
