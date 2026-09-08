"""Acquire the small, pinned SingleStepTests 80286 working set.

The repository is deliberately kept outside Git history in ``.cache``.  A
shallow, blob-filtered sparse checkout retrieves only the metadata, tools, and
the MOV and word ALU MOO files needed by the supported instruction families.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys

# Retain the original direct-script entry point as well as module invocation.
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.run_singlestep import ALU_OPCODES, PHASE5_OPCODES


REPOSITORY = "https://github.com/SingleStepTests/80286.git"
COMMIT = "37c73caf53dcd22d3dd369ff09305d13d117a4fe"
REQUIRED_PATHS = [
    "/README.md",
    "/LICENSE",
    "/revocation_list.txt",
    "/tools/moo2json.py",
    "/tools/README.md",
    "/v1_real_mode/metadata.json",
    *(f"/v1_real_mode/{opcode}.MOO.gz" for opcode in (f"{value:02X}" for value in range(0xB8, 0xC0))),
    "/v1_real_mode/89.MOO.gz",
    "/v1_real_mode/8B.MOO.gz",
    *(f"/v1_real_mode/{opcode}.MOO.gz" for opcode in ALU_OPCODES + PHASE5_OPCODES),
]


def run_git(destination: Path, *arguments: str) -> None:
    subprocess.run(["git", "-C", str(destination), *arguments], check=True)


def acquire(destination: Path, commit: str, repository: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not (destination / ".git").is_dir():
        if destination.exists() and any(destination.iterdir()):
            raise RuntimeError(f"destination is not an empty Git checkout: {destination}")
        subprocess.run(
            [
                "git", "clone", "--depth", "1", "--filter=blob:none", "--no-checkout",
                "--sparse", repository, str(destination),
            ],
            check=True,
        )
    run_git(destination, "fetch", "--depth", "1", "origin", commit)
    run_git(destination, "checkout", "--detach", commit)
    run_git(destination, "sparse-checkout", "set", "--no-cone", *REQUIRED_PATHS)
    run_git(destination, "sparse-checkout", "reapply")
    actual = subprocess.check_output(["git", "-C", str(destination), "rev-parse", "HEAD"], text=True).strip()
    if actual != commit:
        raise RuntimeError(f"SingleStep checkout mismatch: got {actual}, expected {commit}")
    missing = [path.lstrip("/") for path in REQUIRED_PATHS if not (destination / path.lstrip("/")).is_file()]
    if missing:
        raise RuntimeError(f"SingleStep sparse checkout is missing: {', '.join(missing)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--destination", type=Path,
        default=Path(os.environ.get("SPK286_SINGLESTEP_ROOT", ".cache/singlestep-80286")),
    )
    parser.add_argument("--commit", default=COMMIT)
    parser.add_argument("--repository", default=REPOSITORY)
    args = parser.parse_args()
    acquire(args.destination, args.commit, args.repository)
    print(f"SINGLESTEP FETCH PASS: {args.destination} @ {args.commit}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
