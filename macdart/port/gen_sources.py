#!/usr/bin/env python3
# MACDART source-list resolver.
#
# Reads one or more upstream .gypi manifests (which are Python-dict literals
# listing every source for every arch/OS/test), extracts the source entries,
# applies MACDART's arch/OS/test filters, and prints the surviving files as
# absolute paths (one per line) for CMake to consume.
#
# Paths inside a .gypi are relative to that .gypi's own directory.
#
# This is the single point of truth for "what gets compiled": generous on disk
# (extract.sh keeps everything), precise here.
from __future__ import annotations

import argparse
import os
import re
import sys

# --- Filters (a basename is DROPPED if any active pattern matches) ----------

# Unit tests are never part of the shipped binaries.
TEST_RE = re.compile(r"(_test\.(cc|h)$|_test_)")

# Keep arm64; drop every other architecture backend. `_arm\.` matches arm but
# not arm64; `simulator_*` are only used when running under a guest simulator,
# which a native arm64 host never does.
OTHER_ARCH_RE = re.compile(r"(_ia32[\._]|_x64[\._]|_arm[\._]|_mips[\._]|_dbc[\._]|^simulator_)")

# Keep macOS + generic POSIX; drop the other host OSes.
OTHER_OS_RE = re.compile(r"(_linux[\._]|_win[\._]|_android[\._]|_fuchsia[\._]|_openbsd[\._]|_solaris[\._])")

# NOTE: `*_unsupported.cc` are NOT filtered here. "unsupported" means opposite
# things in different subsystems: for malloc_hooks it is the real implementation
# (no tcmalloc/jemalloc), while for io it is a compiled-out stub. Variant choice
# is made explicitly per-target in CMake, not by a blanket rule.


def keep(basename: str) -> bool:
    if TEST_RE.search(basename):
        return False
    if OTHER_ARCH_RE.search(basename):
        return False
    if OTHER_OS_RE.search(basename):
        return False
    return True


def extract_sources(gypi_path: str, exts: tuple[str, ...]) -> list[str]:
    """Return absolute paths of source entries in a .gypi with given extensions."""
    with open(gypi_path) as fh:
        text = fh.read()
    # Strip line comments so we don't pick up filenames mentioned in prose.
    text = re.sub(r"#.*", "", text)
    base = os.path.dirname(os.path.abspath(gypi_path))
    out = []
    # Source entries are quoted strings ending in a known source extension.
    for m in re.finditer(r"""['"]([^'"]+?\.(?:cc|h|dart|S))['"]""", text):
        rel = m.group(1)
        if not rel.endswith(exts):
            continue
        # Arch/OS/test filtering applies only to compiled C++; Dart core-lib
        # source names never carry arch/OS suffixes and must pass through.
        if rel.endswith(".cc") and not keep(os.path.basename(rel)):
            continue
        out.append(os.path.normpath(os.path.join(base, rel)))
    return out


def main(argv) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--gypi", action="append", required=True,
                   help="a .gypi manifest (repeatable)")
    p.add_argument("--kind", choices=["cc", "dart"], default="cc",
                   help="cc = compilable .cc; dart = .dart sources")
    p.add_argument("--exclude-basename", action="append", default=[],
                   help="drop these exact basenames (repeatable)")
    args = p.parse_args(argv[1:])

    exts = (".cc",) if args.kind == "cc" else (".dart",)
    seen = set()
    result = []
    for gypi in args.gypi:
        if not os.path.exists(gypi):
            sys.stderr.write(f"gen_sources.py: missing gypi {gypi}\n")
            return 2
        for path in extract_sources(gypi, exts):
            if os.path.basename(path) in args.exclude_basename:
                continue
            if path in seen:
                continue
            # A listed source may not exist on disk (excluded during extract,
            # e.g. browser libs); skip silently so lists stay buildable.
            if not os.path.exists(path):
                continue
            seen.add(path)
            result.append(path)
    sys.stdout.write("\n".join(result) + ("\n" if result else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
