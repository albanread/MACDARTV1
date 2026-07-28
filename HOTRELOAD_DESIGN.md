# Live code change in MACDART — the "on-the-fly" reload, extracted

An analysis of the feature that lets you edit a class or method in the running
workspace, press Accept, and have the change take effect on **live instances
without losing their state**. This document reverse-engineers what is actually
built, separates what was inherited from the Dart VM from what MACDART added,
and records the design so it can be reasoned about and re-used.

Primary sources, all in-tree: `WORKSPACE_PLAN.md` §5 (the design intent),
`macdart/patches/macdart-port.patch` (the VM API that was added),
`sdk/runtime/vm/isolate_reload.cc` + `become.cc` (the engine underneath),
`macdart/cocoa/workspace_natives.cc` (the native bridge),
`macdart/cocoa/workspace/language.dart` (the orchestration),
`macdart/cocoa/cocoa_host.mm` (the UI-isolate variant).

## 0. One sentence

MACDART exposes the Dart 1.24 VM's **internal, source-based isolate hot-reload
engine** (`Isolate::ReloadSources` + `InstanceMorpher` + `Become`) to guest Dart
through a single added embedder primitive, and wraps it in a workspace that owns
the isolate's source, so a Smalltalk-style *Accept* becomes a synchronous
in-process reload that **morphs live objects** across class-shape changes.

## 1. Two surfaces, from Smalltalk (Do-it vs Accept)

The feature is one half of a pair, mirroring Smalltalk's two evaluation gestures
(`WORKSPACE_PLAN.md` §5):

- **Do-it / Print-it — transient.** `Dart_EvaluateExpr(target, expr)` compiles
  the input as `(…) => expr` in a library's scope and runs it against live
  state. It reads and mutates existing objects but **defines nothing durable**.
  (Dart has no `eval`; this is the VM's expression evaluator, exposed as the
  `wsEval` native.) Not the subject of this doc, but it shares the plumbing.
- **Accept / Define — durable, via hot reload.** Editing a declaration and
  accepting **hot-reloads** the library. This is the on-the-fly feature.

## 2. Inherited vs. added — the crisp split

The engine is **not** new; the access to it is. Being precise about the boundary
is the whole point of the analysis.

| Inherited from the Dart 1.24 VM | Added by MACDART |
|---|---|
| `Isolate::ReloadSources()` — the internal reload driver | **`Dart_WorkspaceReloadSources(force)`** — a new embedder C export that calls it (the one load-bearing addition) |
| `IsolateReloadContext` — diff old vs new program | `Dart_WorkspaceVmStats` — live heap/GC/compile counters for the toolbar |
| `InstanceMorpher` — migrate a live instance to a new shape | the **scratch-file source-of-truth** + USER-region rewrite (`_rebuildAndReload`) |
| `Become::…ForwardIdentity` / `MakeDummyObject` — swap identity so every reference points at the morphed copy | the **SQLite image** as boot source + the `_decls` live mirror |
| atomic cancel on an unsafe edit (`ReasonForCancelling`) | the **rollback + persist-after-success** discipline (§7) |
| the **tag handler** re-reading a library's source | the **two-isolate coordination** — host-driven UI-isolate reload (§8) |
| `Dart_EvaluateExpr`; `Dart_IsReloading` (the *only* public reload export) | the natives (`ws_reload`/`ws_eval`/`ws_requestUiReload`/…) and the Accept UI + compile gate + lint |

The headline: **Dart already had `become`.** Smalltalk-MACVM does not, which is
why MACVM must reboot on a structural class change; MACDART inherits Dart's
`Become` for free and only had to *reach* it.

## 3. The one added primitive

Stock Dart 1.24 exposes reload **only** through the vm-service (Observatory)
`_reloadSources` JSON-RPC — which needs the service isolate running and a client
driving it from outside. That is unusable as the engine of an in-process,
synchronous *Accept*. So the port adds one function (`macdart-port.patch`,
into `dart_api_impl.cc` + a declaration in `dart_api.h`):

```c
DART_EXPORT Dart_Handle Dart_WorkspaceReloadSources(bool force_reload) {
  DARTSCOPE(Thread::Current());                 // Native -> VM state
  Isolate* isolate = T->isolate();
  if (!isolate->CanReload()) {
    return Api::NewError("%s: isolate cannot reload in its current state", CURRENT_FUNC);
  }
  JSONStream js;
  bool success = isolate->ReloadSources(&js, force_reload);
  if (!success) {
    return Api::NewError("reload cancelled: %s", js.ToCString());   // the cancel reason
  }
  return Api::Success();
}
```

That is the entire "feature added to support on-the-fly changes," at the VM
boundary: a thin, synchronous door from guest Dart onto the internal reload
driver. Everything else is the VM's own machinery (below) or workspace
orchestration (above). It is invoked from a native, `Workspace_reload`, exported
to Dart as `wsReload()`.

## 4. The reload engine underneath — the three outcomes

`Isolate::ReloadSources` re-reads each library's **source** through the tag
handler, builds the new program, and diffs it against the loaded one. What
happens to live objects depends on the kind of edit (`WORKSPACE_PLAN.md` §5;
`isolate_reload.cc`):

1. **Method-body edit** → the function's code is swapped; existing instances use
   the new body on their next call. JIT-compiled callers that inlined or cached
   the old code are de-optimised. *Identical to Smalltalk live method redefine.*

2. **Structural edit** (add / remove / reorder instance fields) → for every live
   instance of the changed class, `InstanceMorpher::Morph` (`isolate_reload.cc:140`):
   - allocates a fresh instance in the **new** shape (`Instance::New(to_)`);
   - copies **surviving fields by name** — a precomputed `mapping_` of
     old-offset → new-offset, so a field keeps its value even if it moved
     (type is ignored at copy time);
   - runs the class's **initializing expression** for genuinely-new fields
     (`RunNewFieldInitializers`);
   - calls `Become::MakeDummyObject(old)` — turning the old instance into a
     forwarding filler so **every reference in the heap is rewritten old→new**
     during the reload's identity-forward pass.

   The live object keeps its state across the shape change. *This is exactly the
   `become:` capability MACVM lacks.*

3. **Unsafe edit** (a field's type conflicts with a value a live instance holds,
   or the supertype / type-parameter count changed) → the reload **cancels
   atomically** (`ReasonForCancelling`): no partial state is applied, the old
   program stays intact, and `ReloadSources` returns false with a reason.
   MACDART's response is to roll back (§7) and, if the user still wants the
   change, restart the language isolate — which re-reads the image from source
   and comes back clean. *That restart is the watchdog respawn path.*

The morph is safe because a moving-GC VM already knows how to enumerate and
rewrite every reference; `Become` is that capability aimed at a caller-supplied
forwarding instead of GC compaction.

## 5. Where the "new source" comes from — the scratch file

Dart-1-era reload is **source-based** (kernel/bytecode reload was a Dart-2
thing). So the engine needs to *re-read source* — but MACDART is a **snapshot**
VM: the core and workspace libraries are frozen into the `dartui` binary, not
sitting in `.dart` files the tag handler can re-read. The resolution:

- The language isolate's entry script is a **scratch file** on disk with a
  fixed frame and a rewritable USER region between `_begin`/`_end` markers.
- The workspace holds every accepted declaration in `_decls` (name → source), a
  live mirror of the image.
- `_rebuildAndReload()` (`language.dart:268`) regenerates the USER region from
  `_decls`, writes the scratch file, and calls `wsReload()`. The tag handler
  then re-reads *that file* — now containing the new declaration — and the diff
  proceeds.

So "own the source" is literal: the workspace is the tag handler's source of
truth, and Accept is fundamentally *rewrite the file, then reload it*.

## 6. The Accept pipeline, end to end

```
[UI isolate]  Accept button
  → acceptEditor() / browserAccept()               collect top-level decls from the editor
  → guardedAccept(decls)                            refuse if the debugger is paused
      → checkDecls(decls)                           a REAL compile (dart --compile_all); reject with a line
      → cocoaLint(decls)                            warn-only Cocoa-send check (separate feature)
      → ask('acceptMany', decls)  ───────────────▶  [language isolate]
                                                       _acceptMany(decls):
                                                         capture prev source of each name
                                                         _decls[name] = new source
                                                         _rebuildAndReload():
                                                           rewrite scratch USER region from _decls
                                                           wsReload()  ─────▶ Workspace_reload (native)
                                                                                 → Dart_WorkspaceReloadSources(true)
                                                                                     → isolate->CanReload()
                                                                                     → isolate->ReloadSources()   [§4]
                                                         if reload FAILED:  roll back _decls, reload again, return err  [§7]
                                                         else:              _imageUpsert(name, source) into SQLite
  ◀──────────────────────────────────────────────    "accepted …"  |  the cancel reason
```

The compile gate (`checkDecls`) is belt to the reload's braces: the reload would
also reject non-compiling source, but the up-front `--compile_all` gives a clean
message and a caret line, and never lets a syntactically-broken file reach the
tag handler.

## 7. The invariant that keeps live and saved in agreement

The subtle correctness property (`language.dart:196-219`): **the SQLite image is
written only after a reload succeeds.**

- `_acceptMany` mutates `_decls` (the live mirror) first, captures `prev`, then
  reloads.
- On success → `_imageUpsert` persists the new source. Live and image agree.
- On failure → restore `_decls` to `prev`, reload *that* (back to the last-good
  live state), return the error, and **never touch the image**.

Why it matters: the image is the boot source for the *next* start (and for a
watchdog respawn). If a cancelled reload had already written the image, the next
boot would try to load a class the VM just refused — a workspace that won't
start. Persist-after-success closes that. `_acceptLive` ("Add to World") is the
deliberate exception: it reloads without ever touching the image, so a trial
class evaporates on the next boot.

## 8. The two-isolate problem — you cannot reload the code you are standing in

There are two isolates, and they reload differently:

- **Language isolate — self-reload, synchronous.** Accept arrives as a top-level
  message (`ask('acceptMany', …)`). The reload runs inside that handler and
  targets the workspace library + the user declarations. This is safe because a
  reload swaps code for *future* calls; the currently-executing frame finishes on
  its old code and returns. `isolate->CanReload()` refuses a reload-during-reload.

- **UI isolate — host-driven, deferred.** The UI isolate cannot reload itself
  from its own stack: a UI reload *rebuilds the chrome* (tears down and recreates
  NSViews), and doing that from inside a button handler would destroy the very
  view dispatching the event, while AppKit still holds the isolate's closures
  (`cocoa_host.mm:31-36`). So `wsRequestUiReload()` just **raises a flag**
  (`g_ui_reload_requested`) and returns; the **host** performs the reload at the
  **top of the pump** — between message drains, with no Dart frames live — the
  same flag-and-drain discipline a modal panel needs. The outcome is stashed in
  `g_ui_reload_status` and polled back by `wsUiReloadStatus()`.

This is the general rule the design encodes: **a reload that reshapes the code
currently on the stack must be deferred to a point where that stack is empty.**
The language isolate meets it by construction (top-level message handler); the UI
isolate is walked to it by the host pump.

## 9. Guardrails and failure handling

- **Compile gate** — `checkDecls` (`dart --compile_all`) before any reload; a
  broken buffer never reaches the tag handler.
- **`CanReload()`** — the VM refuses a reload in an unsafe state (e.g. already
  reloading).
- **Atomic cancel** — an unsafe morph applies *nothing* (`ReasonForCancelling`);
  the old program is untouched.
- **Rollback + persist-after-success** (§7) — live and image never drift.
- **Debugger guard** — `guardedAccept` refuses while the language isolate is
  stopped at a breakpoint (`gDbgPaused`), since reloading under a paused frame is
  ill-defined.
- **Watchdog restart as the ultimate fallback** — when a change can't be morphed
  live, restarting the language isolate re-reads the image (source) and
  reconstructs a clean world; the restart *is* the existing respawn path, so the
  unsafe-edit case needs no new recovery machinery.

## 10. What makes it work, and where it stops

**Why it works at all:** three VM properties, none of them added here — a
**moving GC** (so every reference can be enumerated and rewritten), **`Become`**
(identity forwarding built on that), and **source-based reload via the tag
handler** (so "new code" is just "re-read the file"). MACDART's contribution is
to (a) open a synchronous door onto them (`Dart_WorkspaceReloadSources`), and
(b) make the workspace the *owner of the source* the tag handler reads.

**Where it stops** (the honest limits, consistent with the MACVM comparison):

- Liveness is **within a session and within the language isolate.** It reloads
  code and morphs objects; it does **not** snapshot/restore the live heap. A
  restart rebuilds classes from the image *source* and re-runs to recreate
  objects — a very good project file, not a Smalltalk heap image.
- **Spawned demo/game isolates are not reached.** Accept reloads the language
  isolate; a game running under `Isolate.spawnUri` is a separate isolate, so
  "edit it while it runs" means Stop-and-re-run there. The holy-grail live edit
  applies to image classes/apps that run *in* the language isolate.
- **Unsafe structural edits still fall back to restart** — the morph is not
  omnipotent; conflicting field types or a changed supertype cancel the reload.

The design is, in one line: *Dart already had the hard machinery (moving GC +
`become` + source reload); the feature is a synchronous embedder primitive plus
a workspace that owns the source and keeps live and saved honest across it.*
