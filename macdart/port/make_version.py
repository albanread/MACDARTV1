#!/usr/bin/env python3
# MACDART port of tools/make_version.py (originally Python 2).
#
# Generates runtime/vm/version.cc from version_in.cc, filling:
#   {{VERSION_STR}}   - semantic SDK version parsed from tools/VERSION
#   {{BUILD_TIME}}    - a fixed label (deterministic; avoids rebuild churn)
#   {{SNAPSHOT_HASH}} - md5 over the VM files that define snapshot layout
#
# Deviations from upstream: no svn/git probing, no `utils` import, Python 3
# md5 over binary reads, `except E as e`.
from __future__ import annotations

import argparse
import hashlib
import os
import sys

# When these change, VM-produced snapshots may lose backwards compatibility.
VM_SNAPSHOT_FILES = [
    "datastream.h", "object.h", "raw_object.h", "snapshot.h",
    "snapshot_ids.h", "symbols.h",
    "dart.cc", "dart_api_impl.cc", "object.cc", "raw_object.cc",
    "raw_object_snapshot.cc", "snapshot.cc", "symbols.cc",
]

BUILD_TIME_LABEL = "MACDART"


def parse_version(version_file: str) -> str:
    fields = {}
    with open(version_file) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) == 2:
                fields[parts[0]] = parts[1]
    major = fields.get("MAJOR", "0")
    minor = fields.get("MINOR", "0")
    patch = fields.get("PATCH", "0")
    prerelease = fields.get("PRERELEASE", "0")
    prerelease_patch = fields.get("PRERELEASE_PATCH", "0")
    version = f"{major}.{minor}.{patch}"
    # Non-stable point in the release cycle carries a -dev suffix.
    if prerelease != "0" or prerelease_patch != "0":
        version += f"-{prerelease}.{prerelease_patch}.dev"
    return version


def snapshot_hash(vm_dir: str) -> str:
    h = hashlib.md5()
    for name in VM_SNAPSHOT_FILES:
        with open(os.path.join(vm_dir, name), "rb") as f:
            h.update(f.read())
    return h.hexdigest()


def main(argv) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True, help="version_in.cc template")
    p.add_argument("--output", required=True, help="version.cc to write")
    p.add_argument("--version-file", required=True, help="tools/VERSION")
    p.add_argument("--vm-dir", required=True, help="runtime/vm dir for hashing")
    args = p.parse_args(argv[1:])
    try:
        with open(args.input) as fh:
            text = fh.read()
        text = text.replace("{{VERSION_STR}}", parse_version(args.version_file))
        text = text.replace("{{BUILD_TIME}}", BUILD_TIME_LABEL)
        text = text.replace("{{SNAPSHOT_HASH}}", snapshot_hash(args.vm_dir))
        with open(args.output, "w") as out:
            out.write(text)
        return 0
    except Exception as e:  # noqa: BLE001
        sys.stderr.write("make_version.py exception\n")
        sys.stderr.write(str(e) + "\n")
        return -1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
