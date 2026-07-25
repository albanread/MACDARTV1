# MACDART — Cocoa / POSIX FFI plan

Make MACDART useful for building native macOS apps: let Dart V1 call POSIX
functions, create Cocoa objects, invoke methods, and define ObjC subclasses
(delegates / target-action) — as naturally as possible.

## Decisions (locked)

- **Built into the VM as `dart:cocoa`** (a bootstrap library like `dart:io`),
  not a loadable extension. Natural (`import 'dart:cocoa'`), snapshot-able.
- **`noSuchMethod`-dynamic surface** as the core ergonomic. A Cocoa wrapper
  forwards any unknown Dart method to a runtime `objc_msgSend`, with Dart named
  arguments mapping onto ObjC keyword selectors:
  ```dart
  final c = NSColor.colorWithRed(1.0, green: 0.0, blue: 0.0, alpha: 1.0);
  //  → selector "colorWithRed:green:blue:alpha:", args [1,0,0,1]
  ```

## Why the MACVM model (not the compiler model)

The portfolio has three marshaling schools (all source-verified):
| School | Repos | How | Fits MACDART? |
|---|---|---|---|
| AOT/JIT compiler, per-call-site | MacModula2, MacBCPL | LLVM synthesizes a typed `objc_msgSend` cast per call site; selector known at compile time | No — our sends are dynamic (`noSuchMethod`) |
| JIT, per-ABI-shape thunk | MF67 | JIT-synthesize one cached thunk per shape | Later optimization (uses MACDART's arm64 JIT) |
| **VM, dynamic runtime marshal** | **MACVM** | **one fixed-shape C shim + runtime marshal, live `@encode`** | **Yes — adopt this** |

Everyone converged on the same facts: `dlopen`/`dlsym` the runtime (never
static-link objc); one `objc_msgSend` entry (no `_stret`/`_fpret` on arm64 — the
return kind is a token); the shared ABI-token vocabulary (`g f h2-4 i1-2 b s v`,
from MacModula2); `objc_allocateClassPair`+`class_addMethod` for subclassing;
large structs (`b`/`s`, sret-x8) deferred by all.

## Architecture

1. **Symbols** — `dlopen`/`dlsym` (the VM already has these) resolve
   `objc_getClass`, `sel_registerName`, `objc_msgSend`, `objc_retain/release`,
   the class-pair APIs, and POSIX symbols (via `RTLD_DEFAULT`, since libSystem is
   always mapped). Frameworks loaded by path with `RTLD_GLOBAL`.
2. **Dispatch engine** — copy MACVM's `objc_shim.m` nearly verbatim: cast
   `objc_msgSend` to ONE fixed AAPCS64 shape (self, _cmd, 6 GPR, 8 FPR, 4 stack),
   inside `@try/@catch` (an `NSException` becomes a Dart exception, never crashes
   the VM), switching on a return-kind token. Declares real C structs for
   HFA/int-pair returns so clang reads the right registers.
3. **ABI source** — live `@encode` (`method_getTypeEncoding`) as primary, so a
   built app never needs `cocoa.sqlite` present. Port `cocoa_data`'s classifier
   (`encoding.py`/`derive_method_abi.py`) into the VM for the full token set
   (incl. the structs MACVM punts on). Cache per `(Class, selector)`.
   `cocoa_data` stays the **offline generator** + **ABI verification oracle**.
4. **The `dart:cocoa` natives** marshal Dart values → `gpr[]/fpr[]/stack[]` per
   the tokens, call the shim, unmarshal per the return token.
5. **Memory** (moving GC ↔ ARC — Dart has moving GC too): id in an opaque Dart
   wrapper; retain-on-wrap; `Dart_NewWeakPersistentHandle` finalizer →
   `objc_release` (V1 gives us the finalization MACVM hand-rolled); ARC
   +1-family selector classifier; release-with-poison; leak-over-corruption bias.
6. **Ergonomics** — a `CocoaObject` whose `noSuchMethod` builds the selector from
   the Dart `Invocation` (member name + named-arg labels → colons) and sends.
7. **Callbacks / apps** — `objc_allocateClassPair` + typed C IMPs holding an
   integer ticket → look up the Dart receiver → `Dart_Invoke`. Async
   (target/action) + sync (delegates). Plus `NSApplication` bootstrap and
   main-thread discipline (AppKit is main-only).

## Phases

1. **FFI floor** — `dart:cocoa` native lib in the VM; `dlopen`/`dlsym`; the
   `objc_shim`; a POSIX call end-to-end (`getpid`/`write`).
2. **First send** — `[NSString stringWithUTF8String:] → length → UTF8String`.
3. **`@encode` classifier + shape cache** — dynamic `g/f/h2-4/i1-2` sends.
4. **Memory** — wrapper + finalizer + retain/release + +1-family.
5. **Ergonomics** — the `noSuchMethod` `CocoaObject` + named-args→selector.
6. **Callbacks** — class-pair + ticket registry + `Dart_Invoke`; target/action + a delegate.
7. **App** — `NSApplication` + `NSWindow` + a button whose action is a Dart closure.
8. **(Optional)** `cocoa_data`-driven typed-binding generation; large structs (`b`/`s`).

## Reference implementations (read these)

- **MACVM** (the model): `src/runtime/{objc_bridge.rs, objc_shim.m, objc_delegate.rs}`,
  `world/{49_cocoa,50_cocoapad,65_cocoadelegate}.mst`, `cocoa_gui/src/{main,boot,objc}.rs`.
- **MF67** (the JIT-thunk optimization + cocoa_data-at-compile-time): `src/{objc.rs,cocoadb.rs,session.rs,pic.rs}`, `kernel/objc.masm`.
- **MacModula2** (the progenitor; most complete subclassing/delegate/EXTERNAL story): `src/newm2-{sema/cocoadb.rs,llvm/codegen.rs,runtime/objc.rs}`.
- **cocoa_data**: the metadata spine — `schema.sql`, `encoding.py`, `derive_method_abi.py`.
