"""Fetch only pinned public reference files; verify bytes before saving."""

import argparse
import hashlib
import json
from pathlib import Path
import sys
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Path(__file__).with_name("sources.json")


def verified_references(directory):
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    for item in manifest["files"]:
        path = directory / item["name"]
        if not path.is_file():
            raise ValueError(f"missing {path}; run make mcl86-fetch")
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError(f"reference hash mismatch: {path}")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / ".cache/mcl86")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    args.directory.mkdir(parents=True, exist_ok=True)
    for item in manifest["files"]:
        path = args.directory / item["name"]
        if path.exists():
            data = path.read_bytes()
        else:
            with urlopen(item["url"], timeout=60) as response:
                data = response.read()
        if hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise ValueError(f"reference hash mismatch: {path}; existing files are never overwritten")
        if not path.exists():
            path.write_bytes(data)
    verified_references(args.directory)
    print(f"MCL86 REFERENCES PASS: {len(manifest['files'])} pinned files")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print(f"MCL86 ERROR: {error}", file=sys.stderr)
        sys.exit(2)
