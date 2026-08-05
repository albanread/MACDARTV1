# MACDART build

Darwin-arm64 JIT build of the Dart 1.24.3 VM. Owns its build (CMake + Ninja);
no gyp/GN/gclient. The reference tree `../sdk` is read-only, and comes from our
**owned** mirror `albanread/dart-v1-sdk` (a byte-verbatim snapshot of
`dart-lang/sdk` @ 1.24.3) — Dart V1 is EOL, so we do not depend on upstream
staying online. `port/get-sdk.sh` clones it; the build is offline thereafter.

## Layout

```
macdart/
  port/
    extract.sh                 # deterministic copy  ../sdk -> macdart/  (re-runnable)
    gen_sources.py             # .gypi manifest -> arm64/macOS/non-test file list
    gen_library_src_paths.py   # Py3 port: embed core-lib .dart as C arrays
    make_version.py            # Py3 port: version_in.cc -> version.cc
  runtime/{vm,bin,platform,lib,include,third_party}   # extracted engine sources
  sdk/lib/                     # core libraries (Dart source, embedded at build)
  tools/VERSION
  CMakeLists.txt
  build/                       # out-of-tree build dir (generated)
```

## Build

```bash
./port/get-sdk.sh                       # clone the owned Dart 1.24.3 mirror -> ../sdk (once)
./port/extract.sh                       # copy the subset + apply the patch (auto-bootstraps ../sdk)
cmake -G Ninja -B build -S .
ninja -C build dart_engine
```

Produces `build/libdart_engine.a` — the full VM engine (VM + core-lib natives +
generated core-lib source + embedding API), linked against
`build/libdouble_conversion.a`.

## Configuration

Target is the stock **`dart_bootstrap`** (nosnapshot JIT): core libraries are
compiled from embedded C-array source at VM startup, so no prebuilt snapshot is
needed. Defines: `TARGET_ARCH_ARM64 DART_NO_SNAPSHOT DART_PRECOMPILER
DART_SHARED_LIB` + `DEBUG` (Debug config). `HOST_OS_MACOS` / `TARGET_OS_MACOS`
auto-derive from `__APPLE__`. C++14.

## Run

```bash
ninja -C build dart                         # DEBUG dart (asserts, slow: ~0.46s startup)
./build/dart /path/to/script.dart           # V1 Dart: `new` is REQUIRED
```

### Release build (fast — for test runs)

```bash
cmake -G Ninja -B build-release -S . -DCMAKE_BUILD_TYPE=Release
ninja -C build-release dart                 # ~0.02s startup (23× faster than DEBUG)
python3 test/runtests.py ../sdk/tests/language   # auto-uses build-release/dart
```

Release = NDEBUG + -O2 (+ `-fno-strict-aliasing`). Full language suite (4,602
cases) runs in <2 min vs 6-8 min in DEBUG; identical conformance. Keep DEBUG for
bug-hunting (its asserts catch more).

## Status

- [x] Phase 0a — extraction + build system + **engine compiles clean** (213 obj).
- [x] Phase 0b — embedder/`bin` layer linked → **`dart` runs real V1 Dart with
      the JIT on darwin-arm64.** hello / closures / generics / async / exceptions
      all work. `--version` → `1.24.3 (MACDART) on "macos_arm64"`.
- [x] JIT works unsigned (non-hardened runtime → plain mprotect W^X); MAP_JIT not
      needed yet. Source changes so far vs upstream 1.24.3:
      1. `DEBUG`/`NDEBUG` build-config define.
      2. `CPU::FlushICache` macOS → `sys_icache_invalidate` (`runtime/vm/cpu_arm64.cc`).
      3. deopt stub: don't emit `str SP,[SP,#-8]!` (Rt==Rn traps on Apple Silicon)
         (`runtime/vm/stub_code_arm64.cc`).
- [x] Proper test runner: `test/runtests.py` (parallel; expands `//#`/`///`
      multitests; inverts negative tests; parses upstream `.status` so known
      upstream-fails count as XFAIL; separates signal-CRASHES from FAILs; live
      crash streaming to stderr). `python3 test/runtests.py ../sdk/tests/<suite>
      [--stride N --timeout S --jobs J]`.
- [x] **Snapshot build** — `gen_snapshot` (serializes the core snapshot on
      arm64) + a snapshot-loading `dart`. Three executables now:
      `dart_bootstrap` (nosnapshot, 1.6s startup), `gen_snapshot`, and **`dart`
      (snapshot, 0.43s startup, the default).** Engine built twice
      (`dart_engine_nosnap` / `_snap`) because `DART_NO_SNAPSHOT` is a
      compile-time switch. dart:io is in the core snapshot.
- [x] **Full test suites run, zero crashes:**
      **corelib 431 cases → 95.0%** (21 fails all need `-D` env flags);
      **language 4602 cases → 99.1%** — essentially parity with upstream 1.24.3.
      **CRASH=0 across all 5,033 cases.** The only VM code changes are the two
      arm64 fixes. Run: `python3 test/runtests.py ../sdk/tests/<suite>`.
- [ ] Faster still: a RELEASE (NDEBUG) `dart` would cut the ~0.43s DEBUG startup
      a lot (keep DEBUG for bug-hunting).
- [ ] Later: MAP_JIT + `allow-jit` entitlement for signed/notarized
      distribution; re-enable TLS (BoringSSL); triage the ~39 language fails
      (mostly checked-mode / Dart-2-feature / harness-config, not VM bugs).

## Port changes to extracted sources (the actual delta)

Three files under `runtime/` differ from pristine 1.24.3; diff against `../sdk`:
`vm/cpu_arm64.cc` (FlushICache), `vm/stub_code_arm64.cc` (deopt SP push).
Everything else is build scaffolding under `port/` + `CMakeLists.txt`.

## Porting changes to extracted sources

Edits to files under `runtime/` are the port. Find them against the pristine
reference with e.g. `diff -u ../sdk/runtime/vm/cpu_arm64.cc runtime/vm/cpu_arm64.cc`.
