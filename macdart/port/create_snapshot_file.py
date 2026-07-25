#!/usr/bin/env python3
# MACDART port of runtime/tools/create_snapshot_file.py (originally Python 2).
#
# Embeds the two binary snapshot blobs produced by gen_snapshot (the VM-isolate
# snapshot and the core-isolate snapshot) into a C++ source file by filling the
# two `%s` slots of the snapshot_in.cc template. The result defines
# vm_snapshot_data / core_isolate_snapshot_data, which the embedder passes to
# Dart_Initialize so the isolate loads its core libraries from the snapshot
# instead of recompiling them from source.
from __future__ import annotations

import argparse
import sys


def to_c_bytes(path: str) -> str:
    with open(path, "rb") as fh:
        data = fh.read()
    # Comma-separated decimal bytes; compilers handle this fine and it keeps the
    # generated file simple. (Upstream used the same shape.)
    out = []
    for i, b in enumerate(data):
        out.append(str(b))
        out.append(",\n  " if (i % 20) == 19 else ", ")
    return "".join(out)


def main(argv) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--vm_input_bin", required=True)
    p.add_argument("--input_bin", required=True)
    p.add_argument("--input_cc", required=True, help="snapshot_in.cc template")
    p.add_argument("--output", required=True)
    args = p.parse_args(argv[1:])
    try:
        with open(args.input_cc) as fh:
            template = fh.read()
        text = template % (to_c_bytes(args.vm_input_bin),
                           to_c_bytes(args.input_bin))
        with open(args.output, "w") as out:
            out.write(text)
        return 0
    except Exception as e:  # noqa: BLE001
        sys.stderr.write("create_snapshot_file.py exception\n")
        sys.stderr.write(str(e) + "\n")
        return -1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
