# Checking Cocoa sends — the runtime is the database

How `dart:cocoa` stops surprising you at runtime: a mistyped class or selector
becomes a **squiggle at Accept time**, and anything that slips through becomes a
**legible, non-fatal Dart exception** — using the one authoritative Cocoa
database we already own, the loaded Objective-C runtime.

Companion to `WORKSPACE_PLAN.md` (Accept already compile-checks source) and
`COCOA_PLAN.md` (the bridge). Written before the code.

## 1. The database we own

We do not need to ship, generate, or maintain a Cocoa metadata file. The
Objective-C runtime **in the running process** is a complete, authoritative one,
and `Cocoa_send` already queries it every call. For any class + selector it
answers, with zero external files:

- does this class exist? — `objc_getClass`
- does it respond to this selector (instance or class side)? —
  `class_getInstanceMethod` / `class_getClassMethod`
- how many arguments, of what types? — `method_getTypeEncoding` (the same
  `@encode` string the send classifies to pick registers)

It beats Apple's BridgeSupport XML on the axis that matters: it reflects **this
binary on this OS** — exactly the frameworks we linked (AppKit, Metal,
AVFoundation…), the real methods of the running system, and nothing we cannot
actually call. BridgeSupport is a useful *enrichment* later (§5) — it is the
only source that names a method's concrete *return class* and documents free
functions / constants / enums — but it is not the foundation.

## 2. Current state, honestly

The bridge already **detects** a missing method — it does not abort:

- `Cocoa_send` guards `class_getInstanceMethod(...) == NULL` and throws a Dart
  exception before dispatch;
- `objc_shim.m` wraps the real `objc_msgSend` in `@try/@catch`, so even a
  `doesNotRecognizeSelector:` that reached dispatch becomes a status code, then
  a Dart exception.

So the real gaps are narrower than "it crashes on typos":

1. **The throw is only as safe as its caller.** Uncaught in a *fatal* context —
   boot, layout construction, a raw callback — it kills the isolate. Detection
   exists; graceful handling depends on where the call sits.
2. **You learn only when the line runs.** UI code calls a selector once, at
   layout time; a typo in an unexercised branch surfaces late, with a poor
   message ("unknown selector (no method for this class)" — it names neither).
3. **No arity / type / FP-register check at all.** Wrong arg count usually
   becomes a different (caught) selector, but a subtle mismatch is silent
   garbage — and nothing warns when a call trips the marshaler's 8-FP-register
   limit (the FP-register law: floats past the eighth get garbage, no error).

## 3. Two layers

**Layer 1 — the runtime net (loud, never fatal).** Backstops everything,
including dynamically-built selector strings no static pass can see:

- name names in the exception: `NSTableView has no selector 'setEditable:'`, and
  distinguish a not-found class (`send to nil — class 'NSColer' not found`) from
  a wrong selector;
- keep the throw *caught* on the boot/layout paths (the `defer()` wrapper and
  the layout builder already have the try/catch shape) so a bad call is an error
  banner, never a boot exit.

**Layer 2 — the Accept-time lint (the prize).** Accept already compiles the
source and maps errors to the user's line. A Cocoa-lint pass runs there, using
three natives that query the runtime:

```
cocoaClassExists("NSTableView")            -> bool
cocoaSelectorInfo("NSColor", "colorWith…") -> [1, msgArgc, "@encode…"] | null
cocoaNearestSelectors("NSColor", "colr…")  -> ["colorWith…", …]  (edit-distance)
```

It walks the source for the call shapes it can resolve and reports, before the
code ever runs:

- **unknown class** — `Cocoa.cls("NSColer")` → "no such class; did you mean NSColor?"
- **unknown selector** — with a "nearest real selectors" list that turns a typo
  hunt into a fix;
- **wrong arg count** — the selector's colon count vs. the args passed;
- **the FP-register law, finally caught** — count float/double args (and
  struct-of-float args like NSRect, which each consume FP registers) from the
  `@encode`; warn at Accept time when a call would spill past eight.

## 4. Where static checking honestly stops

A dynamically-typed language cannot be fully resolved; this is best-effort,
strongest exactly where typos live:

- **Direct** `Cocoa.cls("NSColor").colorWithCalibratedRed(…)` — class known from
  the literal, first selector fully checkable. The overwhelming majority of
  hand-written call sites, and where every probe-law bite happened.
- **Through a local** `var c = Cocoa.cls("NSColor"); c.setFill();` — a light
  dataflow pass carries the class from the assignment. Common, doable.
- **Chains** `a.foo().bar()` — `foo`'s return is `id` to the runtime, so `bar`'s
  receiver class is unknown; confirm `bar:` exists *somewhere*, not on the right
  class. This is what BridgeSupport's return-type annotations would rescue (§5).
- **Fully dynamic** `obj.send(selString, args)` — invisible by construction;
  Layer 1's net is its only guard, and that is fine.

Result: a squiggle under most mistakes at Accept, a clear named exception under
the rest at runtime, and the process never dies from a typo again.

## 5. Rollout

1. **Layer 1 + the query natives — DONE.** Louder, class-aware exceptions in
   `Cocoa_send`; `cocoaClassExists` / `cocoaSelectorInfo` / `cocoaNearestSelectors`
   querying the runtime (all three shipped up front). Verified headlessly.
2. **The lint pass — DONE.** `cocoaLint(src)` in workspace.dart: a small
   dedicated tokenizer (lexDart drops punctuation, so the lint needs its own),
   the direct `Cocoa.cls("X").sel(...)` shape and the `var c = Cocoa.cls("X")`
   local-dataflow shape, selector rebuilt exactly as `noSuchMethod` does. Runs
   warn-only inside `guardedAccept` after the compile check (never blocks), and
   is drivable headlessly via the `colint <source>` control verb. Catches
   unknown class, unknown selector (+ "did you mean"), and the FP-register limit
   (count `d`/`f` in the `@encode` after the `:` marker). Two gotchas learned:
   skip Cocoa's own Dart members (`send`/`toString`/`handle`…) and require
   parentheses (so bare getters like `.isNil` are not linted); and "has args"
   must be decided from the token after `(`, not from seeing an identifier
   (numbers tokenise as punctuation, so `fillRect([…])` looked 0-arg otherwise).
3. **Optional BridgeSupport enrichment** — parse the framework XML into the
   SQLite image for concrete return-class inference on chains, plus free
   functions / constants / enums.

## 6. Decisions

**Locked:** the loaded runtime is the source of truth (not a shipped DB, not
generated bindings); checking is best-effort static + a total runtime net;
diagnostics map to the user's line through the existing Accept path; nothing
here changes how a valid send behaves. **Open:** how far the local-dataflow
class inference goes before it is not worth it; whether BridgeSupport is worth
its parse for the chain case, or whether a `// cocoa: NSColor` hint comment on a
variable is a cheaper 90% solution.
