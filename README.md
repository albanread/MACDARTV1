# MACDART

A native **Apple Silicon (arm64) JIT** port of the **Dart 1.24.3** virtual
machine — the last release of the **V1** Dart language, from December 2017.

This is a study in high-performance virtual machines, not a product. It exists
because the Dart V1 VM is one of the more interesting JITs to run on modern
Apple hardware, and because keeping it alive is a small act of preservation.

## Why V1, and why this VM

The Dart VM belongs to a distinguished lineage of high-performance object VMs.
Its designers came from **Strongtalk** — the optionally-typed Smalltalk system
whose adaptive-compilation and inline-caching techniques carried through
**HotSpot**, then **V8**, and finally into Dart. Dart 1.x is arguably the last
member of that family to keep Strongtalk's defining idea: **optional typing** —
types you can add for documentation and tooling but which don't change runtime
semantics, over a fast dynamic core.

Dart 2 abandoned that. It became a *soundly* typed language with a separate
"kernel" front-end, compiled ahead of time; the in-VM parser and the optional-
types model were removed. That is a different language and a different machine.

**This project targets V1 specifically:**

- **Not Dart 2** — no sound null-safety, no kernel front-end. V1's recursive-
  descent parser lives *inside* the VM ([`parser.cc`](macdart/) is ~15k lines),
  so the VM alone is the whole language. `new` is required for constructors;
  `Foo()` without `new` is a static call, not a constructor.
- **Not Flutter** — no Skia, no widget framework, no mobile embedder. This is
  the command-line `dart` VM and its core libraries.

The interest here is the machine itself: a generational GC, tagged pointers, an
optimizing JIT that patches its own code and deoptimizes on demand — running as
a native arm64 JIT on Apple Silicon, which it was never built to do (the 2017
arm64 backend existed only for iOS, where Dart ran ahead-of-time and never
patched code at runtime).

## What the port actually is

Upstream Dart 1.24.3 already contained a complete, Apple-ABI-aware arm64 backend.
Making it a *runtime JIT* on macOS took **three small source changes** (see
[`macdart/patches/macdart-port.patch`](macdart/patches/macdart-port.patch)):

1. **`cpu_arm64.cc`** — implement `CPU::FlushICache` on macOS via
   `sys_icache_invalidate`. On iOS this path is `UNREACHABLE()` (AOT never
   patches code); a JIT must flush the I-cache after emitting instructions.
2. **`stub_code_arm64.cc`** — the deoptimization stub pushed every register
   including SP with `str SP, [SP, #-8]!`. That is `Rt == Rn`, which ARM defines
   as *constrained unpredictable* and which **Apple Silicon traps** as an illegal
   instruction (other ARM cores execute it). Special-case the SP push.
3. **`flow_graph_compiler.cc`** — `VisitBlocks` formed `*loop_headers` on a NULL
   pointer on the comments-off path (undefined behaviour). Clang 17 at `-O1+`
   exploits it into a NULL dereference inside the optimizing compiler. Guard the
   call so the null reference is never formed.

Everything else is our own build system. We do **not** reproduce Dart's
gyp/GN/gclient/CI. A hand-written CMake build, plus Python-3 ports of the old
code generators, compiles a chosen subset of the sources (arm64 + macOS +
portable) into three executables:

- **`dart`** — the snapshot-loading JIT (core libraries loaded from an embedded
  snapshot; ~0.02s startup in the release build).
- **`gen_snapshot`** — serializes the core snapshot.
- **`dart_bootstrap`** — a snapshot-free JIT that compiles the core libraries
  from source at startup (used for bring-up).

## Status

Builds and runs real V1 Dart on darwin-arm64 with the JIT: closures, generics,
mixins, exceptions, `async`/`await`, `dart:io`. Against the upstream test
suites (via [`macdart/test/runtests.py`](macdart/test/runtests.py), which
expands multitests, honours the upstream `.status` files, and separates crashes
from failures):

| Suite    | Cases | Conformance | Crashes |
|----------|-------|-------------|---------|
| corelib  | 431   | 95.0%       | 0       |
| language | 4,602 | 99.1%       | 0       |

Zero crashes across all 5,033 cases — essentially parity with upstream 1.24.3.
The remaining failures are tests needing `-D` environment flags, checked-mode
runs, or Dart-2 features — not VM defects.

## Building

The reference sources are **not** vendored in this repo — only the port (the
scripts, the CMake build, and the patch). To build, you supply a Dart 1.24.3
checkout as the source quarry:

```bash
# 1. Get the reference sources (the last V1 release), placed at ../sdk:
git clone --depth 1 --branch 1.24.3 https://github.com/dart-lang/sdk.git sdk

# 2. Extract the needed subset into the owned tree and apply the port patch:
./macdart/port/extract.sh

# 3. Build (CMake + Ninja, C++14):
cd macdart
cmake -G Ninja -B build-release -S . -DCMAKE_BUILD_TYPE=Release
ninja -C build-release dart

# 4. Run some V1 Dart (remember: `new` is required):
./build-release/dart /path/to/script.dart
```

See [`macdart/BUILD.md`](macdart/BUILD.md) for details, the debug build, and the
test runner. The full plan and the reasoning behind it are in
[`PORTING_PLAN.md`](PORTING_PLAN.md).

## The workspace GUI

A native Cocoa IDE for V1 Dart — a Smalltalk-style class browser, a live
workspace, a whole-class editor with a real compile check, and live VM counters —
written in Dart itself through a `dart:cocoa` bridge:

```bash
./start-gui.sh              # foreground; --rebuild, --background, --fresh
```

It runs on `dartui`, the GUI host: the same VM plus a thread-0 AppKit host, so
the UI isolate lives where AppKit is legal while your code runs in a second
isolate that can be killed and respawned without taking the window with it. Your
classes are held as source in a SQLite image at `~/.macdart/workspace.sqlite`,
loaded over the VM snapshot at boot, so an Accept is live *and* survives a
restart — and thanks to this VM's `become`, existing instances morph in place
across a class-structure change. See [`WORKSPACE_PLAN.md`](WORKSPACE_PLAN.md).

## Licensing

The Dart VM and core libraries this project ports are **BSD-3-Clause**:
*"Copyright 2012, the Dart project authors. All rights reserved."* (the
no-endorsement clause names Google Inc.). They also carry an **additional patent
grant** (Dart's `PATENTS` file — a perpetual, royalty-free, irrevocable patent
license). `extract.sh` preserves both as `macdart/LICENSE.dart` and
`macdart/PATENTS.dart`.

The one third-party library actually vendored, **double-conversion**, is under
its own BSD-3-Clause license (*"Copyright 2006-2011, the V8 project authors"*),
kept in its source directory. The other, more encumbered externals listed in
Dart's license preamble (NSS, SQLite, 7-Zip, zlib, …) are **not** included:
this build disables TLS, uses the system zlib via a shim, and extracts only the
command-line VM subset.

The MACDART port itself — the scripts, the CMake build, and
`patches/macdart-port.patch` in this repository — is offered under the
BSD-3-Clause terms in [`LICENSE`](LICENSE).
