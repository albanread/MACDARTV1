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

A sibling project, [**MACVM**](https://github.com/albanread/MACVM), takes the
other branch of that lineage directly: a from-scratch Smalltalk VM (not a
port) with its own moving GC, a JIT that deoptimizes safely on live method
redefinition, and a Cocoa-hosted image — Strongtalk's ideas pursued on their
own terms rather than inherited secondhand through Dart.

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

For a source-grounded tour of that machine — the in-VM parser, the two-tier
speculative JIT, its optimization passes, the ARM64 backend, and the
deoptimization safety net that lets it speculate — see the study in
[`docs/dart-vm-compiler.md`](docs/dart-vm-compiler.md). Two companion notes go
further: [`docs/dart-vm-frontend-guide.md`](docs/dart-vm-frontend-guide.md) shows
how to write a *new* front-end that emits the VM's IL, and
[`docs/dart-vm-hosting-languages.md`](docs/dart-vm-hosting-languages.md) uses the
VM's per-function front-end selection to host another language (Smalltalk, Lisp,
…) *alongside* full Dart — keeping all of `dart:core`.

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

## Benchmarks — the second language runs fast, too

The Smalltalk that runs on this VM isn't a toy: the same checksum-verified
Smalltalk benchmarks run three ways under one microsecond-clocked protocol
([MACVM's `xvm-bench.sh`](https://github.com/albanread/MACVM/blob/main/scripts/xvm-bench.sh):
a cold run, 30 warmup iterations, then 41 single-workload samples, best-of-7,
JIT hot on every VM). **MACDART's Smalltalk-on-the-Dart-VM beats Cog — the
production Squeak/Pharo JIT — on six of seven, and ties the seventh**, and
splits with the sibling [MACVM](https://github.com/albanread/MACVM) Rust
Smalltalk VM (MACDART wins the compute/dispatch-bound benches, MACVM the
allocation-bound ones). µs per iteration, warm — lower is better:

| bench     | MACDART | Cog (Pharo 13) | MACVM |
|-----------|--------:|------:|------:|
| arith     | 715 | 5224 | 1411 |
| fib       | 6935 | 18726 | 9034 |
| sieve     | 196 | 362 | 180 |
| dict      | 457 | 1024 | 255 |
| alloc     | 384 | 701 | 587 |
| richards  | 628 | 2223 | 1087 |
| deltablue | 300 | 280 | 150 |

Cog is never meaningfully ahead: the closest row, `deltablue`, is 299 vs 279 —
inside the harness's noise, so a statistical tie rather than a win for either.
That row was a **4.6× loss** before a twelve-commit front-end arc (1271 → 299 µs)
that removed dispatch overhead from the Smalltalk layer — helper fast-paths,
`(isolate, cid, selector)` caches over the extension-holder resolution,
compile-time symbol interning, per-site block-call lowering. **No VM source was
touched**; the laws that arc established are written up in
[`docs/dart_engine_laws.md`](docs/dart_engine_laws.md), and the full three-way
record is in [`docs/cog_bench.md`](docs/cog_bench.md).

MACVM still wins the allocation-bound three (sieve, dict, deltablue) — a
generational scavenger beats a boxing runtime on allocation churn, which is the
honest structural limit here, not a tuning gap. It has also since narrowed
MACDART's lead on the compute rows (richards 2.3× → 1.7×) with a register-
allocator arc of its own, so these numbers are a snapshot of two moving targets,
not a finish line.

## Building

The reference sources are **not** vendored in this repo — only the port (the
scripts, the CMake build, and the patch). To build, you supply a Dart 1.24.3
checkout as the source quarry. Dart V1 is end-of-life, so we do **not** depend
on `dart-lang/sdk` staying online: the quarry comes from our own byte-verbatim
mirror, [`albanread/dart-v1-sdk`](https://github.com/albanread/dart-v1-sdk)
(a private snapshot of `dart-lang/sdk` @ `1.24.3`, commit `0b0b41ef2` — see its
`PROVENANCE.md`). The build is fully offline once the quarry is present.

```bash
# 1. Get the reference sources (the last V1 release) at ../sdk, from our mirror:
./macdart/port/get-sdk.sh            # clones albanread/dart-v1-sdk -> ./sdk
#   (override the source with MACDART_SDK_MIRROR=<url-or-path> if you have a fork)

# 2. Extract the needed subset into the owned tree and apply the port patch
#    (auto-runs get-sdk.sh if ../sdk is still absent):
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

## Demos, and a native 2D game engine

The workspace's Demos tab spawns each `macdart/cocoa/workspace/demos/*.dart`
file into its own isolate, which computes and sends draw commands to the UI
isolate — a runaway or crashing demo costs its isolate, never the window.
Fifteen ship today: a Mandelbrot zoom (warm-JIT frame times printed live),
Conway's Game of Life, a de Jong strange attractor, flocking boids, a
wireframe globe, and more, alongside three playable games.

The graphical ones render onto a real **Metal game pane** — a from-scratch
C++/Objective-C++ engine (ported from the design of a sibling project,
[MacGamePane](https://github.com/albanread/MacGamePane)) built directly into
`dart:cocoa`: an 8-bit indexed framebuffer with **per-scanline palettes**
(classic raster-bar tricks) and overscan/scroll, GPU-compute sprite
blitting, a text overlay, runtime-compiled shader backgrounds, and an SFX
synthesizer plus ABC-notation chiptune playback over `AVAudioEngine`. A
frame is a *retained-scene delta* — sprite transforms, palette pokes, a
scroll offset — never raw pixels, applied atomically so there is no
mid-frame tearing. For workloads that want the pixels anyway (a live Julia
set, a software rasterizer), a direct-framebuffer mode hands a Dart isolate a
`Uint8List` that *is* the GPU's own shared memory — writes land with no copy
and no protocol. Full design in [`GAMEPANE_PLAN.md`](GAMEPANE_PLAN.md).

Pong is the minimal worked example (← → or A/D, space to serve). Sprite
Invaders and Brickout are the two full games: sprites, a destructible
indexed-pane wall/bunkers erased cell-by-cell through the GPU blitter,
row-pitched SFX, a looping original theme, screen shake, fullscreen, and an
attract mode that serves and plays itself when left alone — which doubles as
an engine test, verified headlessly over the control plane (a `gpsnap` reads
the Metal layer's actual pixels back to PNG, since a window snapshot cannot
see a `CAMetalLayer`).

The **debugger** (a Debugger tab, breakpoints, stepping, frame-local eval)
attaches to any isolate except the UI one — an isolate lookup sits to its
left, so pausing a demo or a game never freezes the interface that's
debugging it. Breakpoints can be conditional (`if EXPR`, evaluated
client-side in the top frame on each hit — this VM has no server-side
condition), which is also the fix for a per-frame breakpoint re-triggering on
every tick. And because `dart:cocoa`'s dynamic `objc_msgSend` bridge trusted
every selector string at runtime, an Accept-time lint now checks class and
selector names against the *loaded Objective-C runtime itself* — the one
Cocoa database that's always exactly right for this binary — catching a
typo'd selector, an unknown class, or a call that would overflow the
bridge's 8-register float-argument limit, before the code ever runs. Design
in [`COCOA_STATIC_CHECK_PLAN.md`](COCOA_STATIC_CHECK_PLAN.md).

## Apps, and running them standalone

Beyond demos, an *app* is an ordinary image class with a `build(ui)` method that
lays out a surface of native Cocoa controls — `label`/`field`/`button`,
`checkbox`/`slider`/`popup`/`secure`/`progress`, a scrolling `list`, `tabs`, a
`scroll` container larger than the window, and a `canvas` that draws (and reports
clicks) through the same op vocabulary the demos use — with `row`/`column`/`grid`
helpers to place them and a handler per widget (`onClick`, `onSlide`, …). Edit
the class, press **Save to Image**, and the app hot-reloads *and re-runs
`build()` while keeping its state* — the reason the App pane exists. Example apps
live in `macdart/cocoa/workspace/apps/` (a calculator, a temperature converter, a
control gallery); install one from the **Apps** menu and Run it on the App tab.
See [`APP_PANE_PLAN.md`](APP_PANE_PLAN.md).

An app **or** a game can also run on its own, **no IDE** — same class, same
image, same hot reload, just a bare window:

```bash
./start-gui.sh --app Calculator                # one image class, full-window
./start-gui.sh --game brickout                 # a game/demo in its own window
./start-gui.sh --game invaders --fullscreen    # a game straight to full screen
```

(equivalently `dartui … workspace.dart --app <Class>` / `--game <Name>`, or the
`MACDART_APP` / `MACDART_GAME` env vars). A game's Metal pane fills the window
exactly as it does on the Demos tab, and `--fullscreen` reuses the pane's own
fullscreen path. An app class must already be in the image — install it in the
workspace first; games and demos are read from `macdart/cocoa/workspace/demos/`.

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
