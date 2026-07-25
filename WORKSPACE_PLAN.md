# MACDART Workspace — a native Cocoa IDE for Dart V1

A native macOS workspace for editing and running Dart V1, modeled on MACVM's
Smalltalk GUI. Tabbed shell (Workspace / Browser / Docs / …), a
syntax-highlighting `NSTextView` editor, and — the load-bearing requirement — a
**remote-control + snapshot interface** so the agent building it can drive the UI
and *see* it.

The UI is written in Dart, calling AppKit through `dart:cocoa`. The native host
(C++/ObjC++) owns only the thread-0 event loop and the class-pair callbacks.
This mirrors MACVM exactly: the "host" is a thin shell; the app *is* guest code.

---

## 1. Threading & isolates — the architecture (locked)

MACVM runs a **UI VM** (builds views, on the main thread) and a **language VM**
(runs user code, off-main), message-passing pickles between them. Dart gives us
this natively with **isolates + `SendPort`/`ReceivePort`** (copy semantics), so
MACVM's `#uiReq`/`#uiReply` protocol maps 1:1 — no hand-rolled pickling.

```
 OS thread 0  (AppKit — the only legal thread for NSView/NSWindow)
 ┌──────────────────────────────────────────────┐
 │ Native GUI host (cocoa_host.mm)               │
 │   • [NSApplication sharedApplication]         │
 │   • CFRunLoopSource pump  ← Dart_HandleMessages│
 │   • [NSApp run]                               │
 │                                               │        background threads
 │ ┌───────────────────────────┐                 │      ┌──────────────────────┐
 │ │ UI isolate  (MACVM's       │  SendPort/       │      │ Language isolate      │
 │ │ "UI worker VM")            │◄─ReceivePort────►│      │ (MACVM's "primary")   │
 │ │  • dart:cocoa builds views │  {req,corr,src}  │      │  • runs user do-its   │
 │ │  • answers AppKit callbacks│  {reply,corr,…}  │      │  • holds program state│
 │ │  • control server (socket) │                 │      │  • kill+respawn = the │
 │ │  • snapshot NSView→PNG     │                 │      │    watchdog           │
 │ └───────────────────────────┘                 │      └──────────────────────┘
 └──────────────────────────────────────────────┘      ┌──────────────────────┐
                                                        │ Compute workers       │
                                                        │  Isolate.spawn(…)     │
                                                        └──────────────────────┘
```

**The crux the isolates alone don't solve.** The `dart` CLI runs `main()` on a
thread-pool thread, *not* thread 0 — empirically `NSThread.isMainThread == 0`,
and AppKit refuses: *"NSWindow should only be instantiated on the main thread!"*.
So:

- The **native host owns `[NSApp run]` on thread 0**, with the UI isolate entered
  and **quiescent**. Dart async (the control socket, timers, cross-isolate
  messages) is serviced by a `CFRunLoopSource` that calls `Dart_HandleMessages()`
  on thread 0, woken by `Dart_SetMessageNotifyCallback`. So all UI-isolate Dart —
  including `main()` — runs on thread 0, and `dart:cocoa` is legal.
- Every **AppKit callback is a fresh top-level re-entry** into the quiescent UI
  isolate (`Dart_EnterIsolate` + `Dart_Invoke`), never a nested call. This is why
  the UI isolate must NOT block in its own Dart message loop.
- **flag-and-drain discipline**: a callback sets an atomic + wakes the run loop;
  heavy/re-entrant work runs top-level on the next default-mode pass. (A
  `reloadData` *inside* a callback re-enters the data source and crashes — MACVM's
  scar, inherited as a rule.)
- The primary→UI reply path is that same default-mode `CFRunLoopSource`; the
  language isolate's `SendPort` message wakes the main run loop and the
  continuation (`Map<int,Completer>` keyed by corr-id) runs on thread 0.

## 2. Remote control + snapshot (the load-bearing feature)

Copied from MACVM's `control.rs` + `objc.rs`, but simpler and better in Dart.

- **Transport**: a loopback `ServerSocket.bind(InternetAddress.loopbackIPv4, 7644)`
  in the UI isolate (`dart:io`). Newline-delimited JSON, one request/reply per
  line. No Rust listener-thread/mpsc dance — the socket's events are pumped on
  thread 0 with everything else.
- **Verbs** (MACVM's proven core + sugar): `ping`, `eval <expr>` → printString,
  `doit <src>` (run on language isolate), `snap <path>` (PNG to file), `view
  <name>` (switch tab), `settext/gettext <pane>`, `click <id>`, `sleep <ms>`.
- **Snapshot — our unique advantage**: MACVM *couldn't* use
  `NSView→NSBitmapImageRep` (Rust's transmuted `objc_msgSend` mis-passes the
  `NSRect` by value on ARM64 — HFA crash), so it fell back to
  `CGWindowListCreateImage`, which needs **Screen-Recording permission** and an
  **on-screen** window. Our `dart:cocoa` bridge passes `NSRect` by value
  correctly (h4, validated), so we use the **permission-free, offscreen**
  `bitmapImageRepForCachingDisplayInRect:` → `cacheDisplayInRect:` →
  `representationUsingType:` (PNG) → `writeToFile:`. The app draws *itself*; no
  screen capture, works headless, captures exactly the app's content.
- **The loop**: agent sends `snap /tmp/shot.png` over the socket → app writes the
  PNG → agent `Read`s the image. Closed loop, drives + sees.

## 3. The UI shell (from MACVM's shipped `world/*.mst`, authoritative)

- **One `NSWindow`**, content stacked in three bands: a **toolbar** (view-switcher
  buttons = the tab bar), a **tabless `NSTabView`** (`setTabViewType: 6`
  NSNoTabsNoBorder — AppKit owns view swap/clip/repaint), and a bottom
  **transcript** dock (newest-first, read-only).
- **Tabs are lazy class-side "view controllers"** that self-register
  (`registerViewNamed:title:icon:container:onShow:`) and build their views on
  first show. Start with **Workspace**, grow **Browser / Docs / Editor** exactly
  as MACVM grew them.

## 4. Editor + syntax highlighting

- `NSTextView` (scroll-wrapped, substitutions off) + a `textDidChange:` delegate →
  **attribute-only** recolor of the `textStorage` inside `beginEditing`/`endEditing`
  after a full-range reset (caret never moves — safe per keystroke).
- **Two Dart wins over MACVM**: (a) Dart strings are already UTF-16, so token
  offsets match `NSRange` natively — skip MACVM's char→UTF-16 remap; (b) the
  tokenizer is plain Dart in the UI isolate (later `package:analyzer`), no host
  boundary. Keep exactly **one** native helper `applySpans(textStorage,
  packedRuns)` to avoid N bridge round-trips per keystroke.
- Forgiving **lexer** for live paint (`{comment,string,keyword,number,ident,…}`);
  reserve the real parser for an explicit **Analyze** gate (red error marks).

## 5. Liveness model — hot reload + `become` (the core, and *more live than MACVM*)

Dart has no `eval`, so naive "REPLs" are compile-time tricks (accumulate-and-
recompile, or Observatory expression-eval) — neither is truly live. The real
engine is **isolate hot reload**, and — decisively — this V1 VM *has `become`*,
which MACVM lacks. Confirmed in-tree: `vm/become.cc`
(`Become::ElementsForwardIdentity`) and `vm/isolate_reload.cc` (`InstanceMorpher`).
So where MACVM must reload the world on a class-structure change, MACDART morphs
live instances in place. The workspace is therefore at least as live as MACVM,
and strictly more so on structural edits.

Two evaluation surfaces, mirroring MACVM's **Do-it** vs **Accept**:

- **Do-it / Print-it — transient, against live state.** `Dart_EvaluateExpr(target,
  expr)` on the language isolate. It compiles the input as `(…) => expr` in the
  scope of a library (later: a selected class / instance / stack frame), so it
  reads and mutates existing objects but defines nothing durable. Expression-only
  → wrap a multi-statement do-it as an immediately-invoked closure `(){…}()`.
  Gated on `isolate->debugger()` (present: `FLAG_support_debugger` defaults true
  in JIT). Selection-or-all, timed, result spliced at the caret captured at
  invocation.
- **Accept / Define — durable, via hot reload.** Editing a method or class body
  and accepting **hot-reloads** that library:
  - *Method-body edit* → code swapped; existing instances use it immediately (==
    MACVM live method redefine).
  - *Structure edit (add/remove/reorder fields)* → `InstanceMorpher` walks the
    heap, allocates each instance in the new shape, **copies surviving fields by
    name** (type ignored), runs initializers for genuinely-new fields, then
    `Become::ElementsForwardIdentity` forwards every reference old→new. Live
    instances keep their state across the shape change — *this is the MACVM `become`
    gap, closed.*
  - *Unsafe edit* (field type conflicts with a live value, changed supertype/type-
    param count) → reload **cancels atomically** (`ReasonForCancelling`, no partial
    state); fall back to restarting the language isolate — that restart *is* the
    watchdog respawn.

Persistence then falls out correctly and needs no accumulate-and-rebuild hack:
declarations live in the workspace library, survive do-its, and redefining them
*morphs* instances rather than resetting them.

**V1 specifics.** Reload here is **source-based** (kernel reload was Dart 2),
triggered via internal `Isolate::ReloadSources` (only `Dart_IsReloading` is a
public C export), re-reading a library's source through the tag handler. The
workspace owns that source, so we drive reload with a small native (`ws_reload`)
plus a `ws_eval` (`Dart_EvaluateExpr`) — the two irreducible new eval primitives.
Both live in a new `macdart/cocoa/workspace_natives.cc`, on the **language
isolate**. Because they touch the tag handler / library source, changes to the
workspace library's Dart are hot-reloaded, not snapshot-rebuilt.

## 6. Class browser & docs

- **Browser** tree from `dart:mirrors` (live structure: libraries/classes/supers/
  members), source text + senders/implementors from the filesystem /
  `package:analyzer` (the rich analog of MACVM's SQLite image queries). MACVM's
  host-side `symbols.rs`/`complete.rs`/`format.rs` mostly *dissolve* — they become
  ordinary Dart in the UI isolate.
- **Docs**: read-only `NSTextView` rendering Markdown via AppKit's own
  `NSAttributedString initWithMarkdownString:…`.

## 7. Callbacks (Phase 6 — `objc_delegate.rs` analog, the gate to interactivity)

Per-role ObjC classes via `objc_allocateClassPair`/`class_addMethod`/
`objc_registerClassPair` (window/text/table/outline/action). Each IMP is a typed
`extern "C" fn` with its `@encode`, so `respondsToSelector:` is native-correct.
**Never store a Dart handle ObjC-side** — a `HashMap<instance_ptr,{gen,ticket}>`
holds an integer ticket + UI-isolate generation; the Dart receiver lives in a
GC-rooted `Map` keyed by ticket. Fail closed (shape default) on unknown instance /
stale generation / re-entrancy. Trampoline: `Dart_EnterIsolate(ui)` +
`Dart_Invoke(receiver, sel, args)` + marshal the return into the ABI register.

---

## Build sequence

- **M1 — host + snapshot proof** ✅ DONE: `dartui` executable (= `dart` +
  `-DDART_UI_HOST`) runs UI Dart on thread 0; built an `NSWindow`+label+button in
  Dart, rendered it offscreen to PNG via `NSView→NSBitmapImageRep`, read it back.
  Proved UI-on-main and the permission-free offscreen snapshot with least code.
- **M2 — persistent app + control server** ✅ DONE: the host now owns `[NSApp run]`
  + a `CFRunLoopSource`/`Dart_HandleMessages` pump (`cocoa_host.mm`).
  `ServerSocket.bind` on 127.0.0.1:7644 in the UI isolate works under the pump
  (proves async/`dart:io`/timers all pump on thread 0). Verbs `ping`/`snap
  <path>`/`title`/`say`/`quit`; drove it live (`say` → snapshot → saw the changed
  label), clean `quit` via `[NSApp terminate:]`. The closed drive-and-see loop.
- **M3 — liveness core** — primitives ✅ PROVEN (via `dart_bootstrap`); language-
  isolate wiring is the remaining integration.
  - `workspace_natives.cc`: `wsEval` (`Dart_EvaluateExpr`) and `wsReload`
    (`Dart_WorkspaceReloadSources` → `Isolate::ReloadSources`, added to
    `dart_api_impl.cc`, non-PRODUCT). Both call `DARTSCOPE` (Native→VM transition).
  - **Do-it/Print-it proven**: expressions (`1+2`→3), multi-statement via IIFE
    (`for` sum→55), and **live-state persistence** (`x=40`→`x+2`→42; a growing
    `List` survives eval-to-eval).
  - **Become gate proven**: `class C{int x=1;}` → instance, mutate `x=42`; add
    `int y=2;` + change `describe()` and reload → *same instance* keeps `x=42`,
    gains `y=2`, runs the new body (`4202`). InstanceMorpher + Become, end to end.
  - **Unsafe-edit cancel proven** (release): a type-param change → atomic cancel
    with a structured `TypeParametersChanged` reason, isolate survives, state
    intact. *Caveat:* the cancel path trips an over-strict DEBUG `ASSERT`
    (`handles_impl.h:104`, `thread->zone()==zone`) — reload allocates the reason
    handle in the longer-lived `zone_` while the tag-handler `Api::Scope`
    (`isolate_reload.cc:626`) has made `thread->zone()` differ. Release is correct;
    smooth the debug assert later (run validation outside the tag-handler scope, or
    adjust reason-handle zone).
  - **Language-isolate wiring ✅ DONE**: `dartui` app (`/tmp/ws_ide.dart`) spawns
    the language isolate (`/tmp/ws_lang.dart`, its root = the scratch file) via
    `Isolate.spawnUri`, exchanges `SendPort`s, and routes socket `doit`/`accept`
    → language isolate → transcript. `accept` keeps a name→source table so
    redefining a class replaces (not duplicates) it. Demonstrated live end-to-end
    and snapshotted: `Counter` + persistent `k` counting 1→2, then redefined with
    a new `step` field → the live `k` morphs (keeps `n=2`, gains `step=10`,
    `bump()`→12). The full multi-isolate liveness loop, driven and seen over the
    socket. (kill+respawn watchdog on fatal/unsafe: still to add.)
- **M4 — Phase 6 callbacks** ✅ DONE (target-action): `cocoa_callbacks.mm`
  registers a runtime `MacdartActionTarget` class (`objc_allocateClassPair` +
  `class_addMethod "macdartInvoke:" "v@:@"`); the IMP trampolines into the UI
  isolate via `Dart_InvokeClosure` on a Dart dispatch closure, keyed by an integer
  ticket in a global instance→ticket map (never a Dart handle ObjC-side). Dart API
  `onAction(control, fn)` in `cocoa.dart`. Demonstrated: 4 `NSButton`s firing Dart
  — synchronous UI mutation ("Say Hi"), and async round-trips to the language
  isolate ("Eval 6*7"→42, "Bump"→counter 1,2). Driven via `performClick` over the
  socket and snapshotted. Remaining roles (window/text/table/outline delegates
  with return values) extend the same pattern per-role.
- **M5 — Workspace editor** — functional editor ✅ DONE; highlighting pending.
  - MACVM-style layout: an editable `NSTextView`-in-`NSScrollView` code pane, a
    **Do It** / **Print It** / **Clear** button row, and a transcript dock below
    (read-only `NSTextView`). Demonstrated live + snapshotted: Print It on an
    expression → `[0,1,4,9,16,25]`; Do It on a `1..100` statement block → `5050`
    (language isolate wraps non-expression input as an IIFE so `return` works).
  - **Selection-aware**: `currentCode()` runs the selection (via `selectedRange`,
    an i2 return → `[loc,len]`, substring in Dart — offsets align since both are
    UTF-16) or the whole buffer.
  - **Syntax highlighting ✅ DONE**: a forgiving Dart lexer in the UI isolate
    (`lexDart` → flat `[start,len,kind]` runs; UTF-16 offsets = `NSRange`), a
    `textDidChange:` delegate (second method on the M4 callback class, wired via
    `onTextChange`) re-highlighting on each edit, and a batched native
    `Cocoa_applySpans` that recolours the `textStorage` attribute-only in one
    begin/end pass (system colours, light+dark). Verified: comment/keyword/type/
    string/number all colour correctly. Also added: physical-interaction fixes
    (redraw flush + immediate feedback) and an app menu (Quit ⌘Q, Workspace Do It
    ⌘D / Print It ⌘P). Optional later: true floating `NSPanel` transcript.
- **M6 — tabbed shell** ✅ DONE: a toolbar of view-switcher buttons over a tabless
  `NSTabView` (`setTabViewType: 6`), a right-anchored live metrics label
  (`cocoaStats` wraps/frees), and the transcript docked below (shared). Three
  tabs, each a container view: **Workspace** (the M5 highlighted editor + Do It /
  Print It / Clear), **Browser** (Refresh → the language isolate's live classes
  via `dart:mirrors` — classes, fields, methods, constructors, top-level vars),
  and **Docs**. Toolbar buttons call `selectTabViewItemAtIndex:`; socket `tab <n>`
  drives it. No new native — all via the existing bridge. Demonstrated +
  snapshotted all three tabs. (Deferred: window-resize reflow / autoresizing.)
- **Watchdog** ✅ DONE: the UI isolate time-boxes every request to the language
  isolate (`ask` + `Future.timeout`); on a timeout — a runaway do-it like
  `while(true){}` — it `Isolate.kill(IMMEDIATE)`s and respawns from the scratch
  file, then replays the accepted declarations via a batched `reset` command
  (respawn-from-source, MACVM's supervisor). Also monitors `onExit`/`onError`.
  Proven: `while(true){}` → killed after 6s, isolate restarted, `Counter` (an
  accepted class) survived, next do-it works, no leaked process. Live object
  state is an honest clean loss.
- **Accept button** ✅ DONE: the Workspace has Do It / Print It / **Accept** / Clear
  (Accept = ⌘S). Accept splits the editor buffer into top-level declarations
  (`splitTopLevel`, respecting strings/comments) and commits them to the language
  isolate's `acceptMany` — they go live via hot reload, morphing existing
  instances, and persist. Tracked in `gAccepted` for watchdog replay. Proven from
  the GUI: define `Pt`+`p`, mutate, redefine `Pt` with a new field + Accept → the
  live `p` morphs (kept `x=42`, gained `z`). **Known limitation surfaced:**
  `dart:mirrors` caches class metadata, so the reflection-based Browser shows a
  class as first reflected — fields added by a later reload don't appear (the
  class IS updated; do-its see it). → the Smalltalk browser below is source-based.
- **M7 — Smalltalk-style class browser** (in progress). Architecture (locked with
  the user): **world = the VM snapshot** (dart:core etc.); **user app = source in a
  SQLite "image" loaded on top**. Browser = World (read-only via mirrors — base
  libs never reload, so no staleness) + User App (editable, from SQLite) → class →
  members → source; Accept commits to the image + hot-reloads.
  - **Foundations ✅ DONE & tested:**
    - **SQLite image store** — `sqlite_natives.cc` (libsqlite3, linked) + a `Db`
      wrapper in cocoa.dart (`open`/`exec`/`query`, parameterised binding). Verified:
      create/insert/query; source with embedded quotes stored intact; real .sqlite
      on disk.
    - **Table data-source callbacks** (the C6 return-value role) — `cocoa_callbacks.mm`
      now has one unified 3-arg dispatch (`_cocoaDispatch(ticket, kind, arg)`) that
      can RETURN values, plus `numberOfRowsInTableView:`,
      `tableView:objectValueForTableColumn:row:`, `tableViewSelectionDidChange:`.
      Dart API `onTable(table, rowCount, cellAt, onSelect)`. Verified: a cell-based
      NSTableView renders a Dart list.
  - **Image wiring ✅ DONE**: the language isolate opens the SQLite image
    (`decls(name,kind,category,source)`); boot loads user decls over the snapshot
    and hot-reloads them live; `acceptMany`/`accept`/`remove` UPSERT/DELETE + reload;
    the watchdog respawn re-reads the DB (in-memory `gAccepted` replay retired).
    Verified: accept persists; relaunch reloads `Counter`/`Pt` from the image with
    no re-accept (`new Counter().bump()`→1 after restart).
  - **Multi-pane browser ✅ DONE**: Browser tab is now `[User App | World]` +
    `[Accept | Remove]` over Classes │ Members `NSTableView`s + an editable,
    highlighted Source pane. User App = image classes → members (parsed from
    source) → class source (Accept commits to the image + reloads; Remove deletes).
    World = base libraries → classes, read-only via mirrors (accurate — they never
    reload). Demonstrated + snapshotted both categories.
  - **Four-pane browser ✅ DONE** (MACVM Browser-V2 shape, adapted to Dart):
    **Categories** (User App + world libraries) │ **Classes** │ **Variables** │
    **Methods**, with an **instance/class** toggle and a **Comment / Definition /
    Source** pane + Accept/Remove. Panes select (no name-editing); the source pane
    edits. Members are records `[side(i/c), kind(var/method), signature, source]`
    parsed from the class source (user app) or via mirrors (world). Source-pane
    modes: Definition = full class source (whole-class Accept); Source = the
    selected member's source (member-level Accept via in-source replace); Comment =
    the class comment stored in the image (`comment` column). Verified: instance vs
    class members, User App (Account: balance/owner/deposit/…) and World (dart:cocoa:
    Cocoa/Db/NSString) both browse; highlighted source.
  - **Remaining polish:** protocols pane + New Class/New Method buttons (MACVM has
    them); Docs as markdown; Find/senders; the debug reload assert; window-resize
    reflow; image path → `~/.macdart/` for cross-session persistence.

### Repo layout (new)
- `macdart/cocoa/cocoa_host.mm` — the thread-0 GUI host (M1/M2). Linked only into
  `dartui`. `bin/main.cc` branches to it under `-DDART_UI_HOST`.
- CMake target `dartui` mirrors `dart` + `cocoa_host.mm` + `DART_UI_HOST`.
- The workspace UI is Dart; it will live under `macdart/cocoa/workspace/`.

Foundations reused: `dart:cocoa` bridge (done), `@encode`→AAPCS64 classifier
(done, incl. NSRect-by-value → the snapshot), memory model (done). New native
code is only three things: the host loop (M1/M2), the class-pair callbacks (M3),
and the batched `applySpans` (M4).
