#!/usr/bin/env python3
"""MACDART test runner.

A pragmatic re-implementation of the parts of Dart's test.py that matter for
measuring VM health and finding VM bugs:

  * Multitests: a file with `/// tag: outcome` markers is expanded into the
    standard variants (`none` + one per tag); each variant is a separate case
    with its own expected outcome. Variants run in a temp dir with sibling
    *.dart symlinked so relative imports still resolve. (We never write into
    the read-only reference tree.)
  * Negative tests (`*_negative_test.dart`) expect a non-zero (clean) exit.
  * Production mode (no --checked): `static type warning` / `dynamic type error`
    / `checked mode compile-time error` variants are expected to PASS; only
    `compile-time error` / `runtime error` expect a clean non-zero exit.
  * Result buckets: PASS / FAIL / CRASH / TIMEOUT. A CRASH is a *signal* death
    (SIGILL/SEGV/ABRT/...) — never an expected outcome, always a real VM bug.
    This is the bucket worth hunting.

Not modelled: status-file expectations (upstream known-fails), checked-mode
runs, tests needing packages beyond expect/async_helper. Such cases surface as
FAIL, not CRASH, so they don't pollute the bug signal.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
# Default to the release build if present (faster), else the debug build.
DART = os.path.join(HERE, "..", "build-release", "dart")
if not os.path.exists(DART):
    DART = os.path.join(HERE, "..", "build", "dart")
PKGS = os.path.join(HERE, ".packages")

# The tests import package:expect / package:async_helper from the reference
# checkout (../../sdk/pkg). .packages holds machine-specific absolute paths, so
# generate it on demand rather than committing it.
def _ensure_packages():
    if os.path.exists(PKGS):
        return
    sdk = os.path.abspath(os.path.join(HERE, "..", "..", "sdk"))
    lines = []
    for pkg in ("expect", "async_helper"):
        lib = os.path.join(sdk, "pkg", pkg, "lib")
        if os.path.isdir(lib):
            lines.append(f"{pkg}:file://{lib}/")
    if lines:
        with open(PKGS, "w") as fh:
            fh.write("\n".join(lines) + "\n")


_ensure_packages()

# Our configuration, used to evaluate .status section conditions. arm64/macos
# never appear in 1.24.3 status files, so arch/system-specific sections simply
# don't match (correct) while unconditional and $runtime==vm sections do.
CONFIG = {
    "compiler": "none", "runtime": "vm", "mode": "debug", "checked": "false",
    "arch": "arm64", "system": "macos", "browser": "false", "strong": "false",
    "host_checked": "false", "unchecked": "true", "csp": "false",
    "minified": "false", "compilation_server": "false",
}
# Outcomes in a .status entry that mean "not expected to plainly pass".
NONPASS = {"Fail", "RuntimeError", "CompileTimeError", "MissingCompileTimeError",
           "Timeout", "Crash", "MissingRuntimeError"}


def eval_condition(cond: str) -> bool:
    """Evaluate a .status section condition like `$runtime == vm && $mode == debug`."""
    expr = re.sub(r"\$(\w+)", lambda m: '"%s"' % CONFIG.get(m.group(1), ""), cond)
    expr = expr.replace("&&", " and ").replace("||", " or ")
    # Quote bare RHS identifiers (none, vm, debug, ...) but not operators.
    expr = re.sub(r'(?<![\w"])([A-Za-z_]\w*)(?![\w"])',
                  lambda m: m.group(1) if m.group(1) in ("and", "or", "not")
                  else '"%s"' % m.group(1), expr)
    try:
        return bool(eval(expr, {"__builtins__": {}}, {}))  # noqa: S307 - trusted input
    except Exception:
        return False


def load_status(suite: str):
    """Return {test_key: set(outcomes)} merged across applicable status sections."""
    status = {}
    for root, _, names in os.walk(suite):
        for n in names:
            if not n.endswith(".status"):
                continue
            active = True
            with open(os.path.join(root, n), encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.split("#", 1)[0].strip()
                    if not line:
                        continue
                    if line.startswith("[") and line.endswith("]"):
                        active = eval_condition(line[1:-1])
                        continue
                    if not active or ":" not in line:
                        continue
                    key, outs = line.split(":", 1)
                    outcomes = {o.strip() for o in outs.split(",") if o.strip()}
                    status.setdefault(key.strip(), set()).update(outcomes)
    return status

OUTCOMES = {
    "ok", "compile-time error", "runtime error", "static type warning",
    "dynamic type error", "checked mode compile-time error", "continued",
}
# Outcomes that, in production mode, actually stop a clean run.
ERROR_OUTCOMES = {"compile-time error", "runtime error"}

# Multitest markers appear as `//# 01: compile-time error` (1.24.3) or the older
# `/// 01: ...` form. Match either.
MARKER = re.compile(r"//[/#]\s*(\w+):\s*(.+?)\s*$")


def marker_of(line: str):
    """Return (tag, outcome_set) if `line` carries a multitest marker, else None."""
    m = MARKER.search(line)
    if not m:
        return None
    outs = {o.strip() for o in m.group(2).split(",")}
    if not (outs & OUTCOMES):
        return None  # a plain /// doc comment, not a multitest marker
    return m.group(1), outs


def analyze(path):
    """Return (is_multitest, lines, {tag: outcome_set})."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    tags = {}
    for ln in lines:
        mk = marker_of(ln)
        if mk:
            tags.setdefault(mk[0], set()).update(mk[1])
    return (len(tags) > 0), lines, tags


def variant_source(lines, keep):
    """Lines for variant `keep` (None => the `none` variant)."""
    out = []
    for ln in lines:
        mk = marker_of(ln)
        if mk is None:
            out.append(ln)
        elif mk[0] == keep:
            out.append(ln)  # keep code; the /// marker is just a comment
        # lines tagged with other tags are dropped
    return "\n".join(out)


def expectation(tags, keep):
    if keep is None:
        return "pass"
    return "error" if (tags[keep] & ERROR_OUTCOMES) else "pass"


def run_dart(script, timeout):
    """Return (returncode, timed_out). Signal deaths give returncode < 0."""
    try:
        p = subprocess.run(
            # Tests don't need the service protocol; skipping it avoids the
            # service-isolate setup and the vmservice resource dependency.
            # (Startup is ~0.4s in the DEBUG snapshot build regardless; a
            # RELEASE build would cut it much further — a future optimization.)
            [DART, "--no_support_service", "--packages=" + PKGS, script],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=timeout)
        return p.returncode, False
    except subprocess.TimeoutExpired:
        return None, True


def classify(expect, rc, timed_out):
    if timed_out:
        return "TIMEOUT"
    if rc is not None and rc < 0:
        return "CRASH"          # killed by a signal
    ok = (rc == 0)
    if expect == "pass":
        return "PASS" if ok else "FAIL"
    return "PASS" if not ok else "FAIL"   # expect == error


REL_IMPORT = re.compile(r"""^\s*(?:import|part)\s+['"](?!package:|dart:)""", re.M)


def run_variant_in_tmp(orig, content, timeout):
    d = os.path.dirname(orig)
    tmpd = tempfile.mkdtemp(prefix="macdart_mt_")
    try:
        # Only build the sibling symlink farm when the variant actually pulls in
        # a relative file — the common case (package:expect only) skips it, which
        # keeps multitests nearly as fast as ordinary tests.
        if REL_IMPORT.search(content):
            for f in os.listdir(d):
                if f.endswith(".dart"):
                    try:
                        os.symlink(os.path.join(d, f), os.path.join(tmpd, f))
                    except FileExistsError:
                        pass
        vp = os.path.join(tmpd, "macdart_variant.dart")
        with open(vp, "w") as out:
            out.write(content)
        return run_dart(vp, timeout)
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


def apply_status(result, status, keys):
    """Fold in .status expectations. keys = candidate status keys (specific+base)."""
    outs = set()
    for k in keys:
        outs |= status.get(k, set())
    if outs & {"Skip", "SkipByDesign", "SkipSlow"}:
        return "SKIP"
    if result == "PASS":
        return "PASS"
    if result == "CRASH":
        return "XCRASH" if "Crash" in outs else "CRASH"      # XCRASH = known-bad
    if result in ("FAIL", "TIMEOUT"):
        return "XFAIL" if (outs & NONPASS) else result       # XFAIL = matches upstream
    return result


def run_one_file(path, timeout, status):
    """Return list of (case_name, result) for this file (>1 for multitests)."""
    is_multi, lines, tags = analyze(path)
    base = os.path.basename(path)[:-5]  # drop .dart
    results = []
    if not is_multi:
        expect = "error" if path.endswith("_negative_test.dart") else "pass"
        rc, to = run_dart(path, timeout)
        r = classify(expect, rc, to)
        results.append((path, apply_status(r, status, [base])))
        return results
    for keep in [None] + sorted(tags):
        tag = keep or "none"
        content = variant_source(lines, keep)
        rc, to = run_variant_in_tmp(path, content, timeout)
        r = classify(expectation(tags, keep), rc, to)
        results.append((f"{path}/{tag}",
                        apply_status(r, status, [f"{base}/{tag}", base])))
    return results


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("suite", help="directory of *_test.dart files")
    ap.add_argument("--stride", type=int, default=1, help="run every Nth file")
    ap.add_argument("--max", type=int, default=10 ** 9)
    ap.add_argument("--timeout", type=int, default=30)
    ap.add_argument("--jobs", type=int, default=max(2, (os.cpu_count() or 4) - 1))
    ap.add_argument("--show", type=int, default=40, help="max failures to list")
    ap.add_argument("--no-status", action="store_true",
                    help="ignore .status files (raw pass/fail)")
    ap.add_argument("--dart", default=DART, help="path to the dart binary")
    args = ap.parse_args(argv[1:])
    globals()["DART"] = args.dart
    print(f"dart = {args.dart}", file=sys.stderr)

    status = {} if args.no_status else load_status(args.suite)

    files = []
    for root, _, names in os.walk(args.suite):
        for n in sorted(names):
            if n.endswith("_test.dart"):
                files.append(os.path.join(root, n))
    files.sort()
    files = files[:: args.stride][: args.max]

    buckets = {k: 0 for k in
               ("PASS", "FAIL", "CRASH", "TIMEOUT", "XFAIL", "XCRASH", "SKIP")}
    crashes, fails = [], []
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(run_one_file, f, args.timeout, status): f for f in files}
        for fut in as_completed(futs):
            for name, res in fut.result():
                buckets[res] += 1
                if res == "CRASH":
                    crashes.append(name)
                    print("CRASH " + name, file=sys.stderr, flush=True)  # live
                elif res == "FAIL":
                    fails.append(name)

    # "real" problems = ones NOT expected by the status files.
    real = buckets["PASS"] + buckets["FAIL"] + buckets["CRASH"] + buckets["TIMEOUT"]
    print(f"\nsuite={args.suite}  files={len(files)}  cases={sum(buckets.values())}")
    print(f"  PASS={buckets['PASS']}  FAIL={buckets['FAIL']}  "
          f"CRASH={buckets['CRASH']}  TIMEOUT={buckets['TIMEOUT']}")
    print(f"  (expected-fail={buckets['XFAIL']}  expected-crash={buckets['XCRASH']}  "
          f"skip={buckets['SKIP']}  — matched upstream .status)")
    if real:
        print(f"  conformance (of tests expected to pass) = "
              f"{100*buckets['PASS']/real:.1f}%")
    if crashes:
        print(f"\n--- UNEXPECTED CRASHES ({len(crashes)}) — real VM bugs to fix ---")
        for c in sorted(crashes)[: args.show]:
            print("  " + c)
    if fails and args.show:
        print(f"\n--- UNEXPECTED FAILURES (sample of {len(fails)}) ---")
        for f in sorted(fails)[: args.show]:
            print("  " + f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
