# User apps in the workspace — the App surface

How someone builds their own Cocoa application *inside* dartui: real buttons,
fields, lists and tabs, laid out and wired up in their own Dart classes, running
live against the image — and popped out into a real window when it grows up.

Companion to `WORKSPACE_PLAN.md` (the workspace itself) and `COCOA_PLAN.md`
(the bridge). Written before the code, so the constraints are argued once.

## 1. The constraint that decides the shape

Only the UI isolate may touch AppKit: it is the one pinned to thread 0, and
AppKit refuses NSWindow anywhere else (`WORKSPACE_PLAN.md` §1). But user code
must run in the **language isolate**, because that is where everything that
makes this a workspace lives:

- the image — user classes are loaded from SQLite and hot-reloaded on Accept;
- **morphing** hot reload — a structural edit keeps live instances and their
  field values, which is the whole "more live than MACVM" claim;
- the debugger — the Debugger tab targets `macdart_ws_lang`, so you can set a
  breakpoint inside a button handler and the window stays alive while you sit
  on it (an isolate cannot debug itself);
- the watchdog — a runaway user loop is killed and respawned without taking the
  window, the unsaved editor buffer, or anything else down with it.

Both facts cannot hold if user code calls `dart:cocoa` directly. So it does not.

**The App surface is a view server.** The user's app never imports `dart:cocoa`
and never sees a `Cocoa` handle. It *describes* widgets and *receives* events;
the UI isolate materialises real NSViews and routes events back. Identical in
spirit to the Demos tab (`macdart/cocoa/workspace/demos/`), which already proves
the pattern — except demos push pixels, and apps push retained-mode controls.

## 2. Surfaces — the pane is not special

A **surface** is a place an app's widgets live. There are two kinds and the app
cannot tell them apart:

- **the App pane** — embedded in the workspace window;
- **a window** — a real NSWindow with a title bar, a close button and a resize
  grip.

`build(ui)` is byte-identical either way; only `ui.width` / `ui.height` differ.

**One app runs at a time, on exactly one surface.** Pop Out does not open a
second copy — it *moves* the running app from the pane into a window, and Pop In
moves it back. That keeps the model small enough to hold in your head: there is
the app, and there is wherever it currently is.

Two things follow, and they are why the abstraction earns its keep even with a
single app:

1. **Moving preserves the app.** Popping out destroys the old surface's views,
   creates the window, and re-runs `build()` — against the **same instance**.
   The app does not restart, does not reload, and does not know it moved. A
   calculator mid-sum keeps its accumulator.
2. **A window-hosted app is nearly a standalone app.** The end of this road is
   `dartui --app Calc`: the same class, out of the same image, in its own
   process with no workspace chrome (§10, M5). That is the deployment story for
   things people build here, and the surface abstraction is what makes it a
   configuration rather than a rewrite.

The message envelope still names its surface (`'pane'`, `'win'`) even though
only one is ever live. It costs one field in two message shapes and it is the
difference between "an app may one day own a second window" being a change and
being a rewrite. Individual commands do **not** carry it.

## 3. What the user writes

A plain class in the image with a `build(ui)` method. No base class, no
framework ceremony, nothing to import:

```dart
class Calc {
  var acc = 0.0, pending = null, display = '0';

  build(ui) {
    ui.title('Calculator');
    ui.field('d', text: display, frame: [8, 8, 216, 30],
             align: 'right', readOnly: true);
    var keys = ['7','8','9','/','4','5','6','*','1','2','3','-','0','.','=','+'];
    ui.grid('pad', frame: [8, 46, 216, 190], cols: 4, gap: 4, of: keys,
            each: (id, key) => ui.button(id, title: key, onClick: (_) => press(key)));
  }

  press(String key) {
    // ... arithmetic on acc / pending / display ...
    ui.set('d', text: display);
  }
}
```

The API shape is **the same one `workspace.dart` uses on itself** —
`button(id, title:, frame:, onClick:)`, handlers as closures. Learning to write
an app teaches the workspace's own idiom, and an app can graduate into real
workspace code without being rewritten.

Handlers are **closures held in the language isolate**, keyed by widget id. The
UI isolate only ever sends `(surface, id, kind, value)`; it holds no Dart
handles belonging to the app.

### The payoff this exists for

Edit `build()`, press Accept, and the layout changes **while `acc` keeps its
value**. Hot reload morphs the instance; the workspace re-runs `build()`. This
is `WORKSPACE_PLAN.md`'s central claim made visible in a pane you can point at.

## 4. The wire

Both directions reuse machinery that already exists; one seal has to be broken.

**app → UI** (batched, pushed):

```
['appui', surfaceId, gen, cmds]
  ['clear']
  ['add',    kind, id, props]     kind: 'button' | 'field' | 'list' | …
  ['set',    id, props]
  ['remove', id]
  ['title',  text]
  ['focus',  id]
```

Plain lists, maps, strings and numbers only — port-safe by construction.

*This needs one change to the host.* `spawnLanguage()` currently does
`gLang = await fromLang.first; fromLang.close();` — there is no channel for the
language isolate to speak first. Keep that port open and listen on it. A clock
app that repaints on a Timer needs to push without an event to answer.

**UI → app** (events): an ordinary `ask()`, deliberately —

```
gLang.send(['appevent', [surfaceId, id, kind, value], replyPort])
```

Fire-and-forget would have been simpler and is wrong. Routing events through
`ask()` inherits three protections already built and already tested:

- the **6-second watchdog** covers a runaway click handler; without a reply
  there is nothing to time out, and a `while(true)` in `onClick` would hang the
  language isolate silently forever;
- the **`gDbgPaused` guard** already refuses work while you are stopped at a
  breakpoint, so clicks during a debugging session are refused loudly instead
  of queueing invisibly and all firing on Continue;
- **generation checking** already discards events aimed at an isolate that has
  since been killed.

Event kinds: `click`, `toggle`, `select` (row/index), `text`, `enter`,
`resize`, `close`.

## 5. Widget vocabulary

Curated, not arbitrary selectors. The dynamic bridge **aborts the process** on
an unknown selector (bitten twice — `NSTableView setEditable:`), so a user typo
must not be able to reach `objc_msgSend`. Users get a verified set; the escape
hatch is a later decision, not a v1 feature.

**Proven in this codebase already** — every one of these is live in
`workspace.dart` today:

| kind | backing | proven by |
|---|---|---|
| `label` | NSTextField, non-editable | `label()` |
| `field` | NSTextField, editable | `gDbgEvalField`, `gFindField` |
| `button` | NSButton | `button()` |
| `popup` | NSPopUpButton | `gEdPicker` |
| `list` | NSTableView + `onTable` | Browser's four panes |
| `text` | NSTextView in NSScrollView | `scrolledTextView()` |
| `box` | NSBox | `texturedBox()` |
| `image` | NSImageView | `gDemoView` |
| `canvas` | NSImage + `Pixmap` blit | the Demos tab |

`canvas` is worth calling out: it reuses the demo draw protocol wholesale, so an
app gets a drawing area and the two features share one renderer.

**Needs a probe before shipping** (§ the probe law): `checkbox`/`radio`
(`setButtonType:`), visible `tabs` (`setTabViewType(0)` — the workspace uses
type 6, tabless), `slider` (NSSlider), `progress` (NSProgressIndicator).

## 6. Layout and coordinates

**The wire carries absolute frames only.** `grid`, `row`, `column` are pure Dart
arithmetic in the language-side proxy. Two reasons: the UI isolate stays dumb
(less code on the thread that must never wedge), and users can write their own
layout helpers without touching the bridge or waiting for us to add one.

**Coordinates are top-left**, converted UI-side against the surface height —
the same choice the demo protocol made. Nobody should have to learn AppKit's
flipped origin to put a button under another button.

Autoresize masks are available per widget as an optional prop, but the primary
answer to resizing is §7: re-run `build()` with the new bounds.

## 7. Lifecycle

**Construction** uses the workspace-variable path, not mirrors:
`apprun Calc` → `wsEval('_app = new Calc()')`. `dart:mirrors` caches class
metadata and goes stale after a reload (a known trap here — it is why the
Browser is source-based), so it is used for nothing that a reload can invalidate.
Everything after construction is plain dynamic dispatch on the stored object.
`AppSurface` is declared in `language.dart`, hence in the same library as user
declarations, so both the message loop and user code see it directly.

| event | what happens |
|---|---|
| **Accept** on the app's class | hot reload morphs the instance, then `build()` re-runs — fresh closures, preserved state |
| **Pop Out / Pop In** | destroy views, create the other surface, re-run `build()`; same instance, state intact |
| **window closed** by the user | `close` event to the app, then the app stops — closing a window is an explicit "I'm done"; Pop In is how you put it away and keep it |
| **surface resized** | new bounds handed over, `build()` re-run (debounced) |
| **watchdog respawn** | the surface clears and says why, then re-runs from the image |
| **`rebuildUi()`** | the UI isolate keeps the surface's spec and re-materialises it — exactly as `gDemoImage` survives a rebuild today |
| **workspace quits** | a popped-out window closes with it |

### The `rebuildUi` gotcha, named before it bites

`rebuildUi()` calls `disposeCallbacks()`, which invalidates **every** callback
ticket in the process. Pop-out windows are not subviews of `gContent`, so they
survive the teardown *visually* — and would come back with dead buttons. A
window full of controls that no longer respond is worse than one that vanished.
Two candidate fixes: scope tickets per surface so a rebuild only disposes the
pane's, or re-materialise every surface (windows included) after `buildChrome()`
returns. The second reuses the spec-replay path that already has to exist, and
is the one to build first.

## 8. Failure containment

The rule the workspace already lives by — a bug in one thing costs that thing,
never the window — extended to apps:

- `build()` throws → error banner on that surface, previous UI kept, workspace
  untouched; the app is still there to be fixed and re-Accepted.
- a handler throws → logged to the transcript, the app keeps running.
- a handler runs away → the watchdog kills and respawns the language isolate;
  surfaces clear and rebuild from the image (§7).
- a handler stops at a breakpoint → the GUI stays live because it is a different
  isolate, and further clicks are refused with a reason rather than queued.

## 9. Control plane and testing

Everything here is drivable from `macdart/tcl/dartui.tcl`, because in this
project a feature that cannot be driven headlessly is a feature that cannot be
regression-tested. One app means no surface arguments: every verb addresses
whatever is running, wherever it currently is.

```
apps                   list image classes that look like apps
apprun <Class>         run one in the pane
appstop
appout                 move it out into a window
appin                  move it back into the pane
apptree                dump ids / kinds / titles / frames as text
appclick  <id>
appset    <id> <text>
appselect <id> <row>
appget    <id>
snap <path>            captures the app's current surface when one is popped out
```

The test that proves the whole loop, and that goes into `regress.tcl`: build the
calculator, `appclick k7`, `k+`, `k8`, `k=`, assert `appget d` reads `15`; then
`appout` and assert the tree survived the move *and* the accumulator with it —
`appclick k+ k1 k=` in the window must read `16`, which is only true if the same
instance moved. Then `uirebuild` while popped out, and assert the window's
buttons still fire (§7's ticket trap, caught by a test rather than by a user).
Plus a snapshot on each surface for the visual.

## 10. Milestones

- **M1 — the loop, end to end.** ✅ DONE. Pane surface, push channel (the
  handshake port stays open), `label`/`field`/`button`, click / text / enter
  events, the verbs above, an Apps menu over `apps/`, four worked examples, and
  19 suite checks including both teardown paths. Three things it taught:
  `appclick` has to *wait* for the app to act (three async hops, so a driver
  that returns on the first one reads the state before the click it just made —
  hence `settle`, which replaced the suite's guessed sleeps); `NSTextAlignment`
  uses the UIKit order (centre 1, right 2), not the legacy AppKit one; and the
  compile gate had silently disabled itself when run from `build-release/`,
  which is how source that does not compile had got into the image.
- **M2 — the second surface, early on purpose.** Window surface, Pop Out / Pop
  In with state preserved, `close` and `resize` events, the `rebuildUi` ticket
  fix (§7). Built immediately after M1 rather than last, because an abstraction
  with only one implementation is an abstraction nobody has tested — and because
  moving a live app between hosts is the feature that proves the whole design.
- **M3 — vocabulary.** ✅ PARTIAL. `checkbox` (NSButton switch), `slider`
  (NSSlider), `popup` (NSPopUpButton), `secure` (NSSecureTextField), `progress`
  (NSProgressIndicator), `box` (NSBox group) shipped — handlers are wrapped so
  the app gets a typed value (bool/double), and `set` grew `value`/`checked`/
  `items`/`selected`. Live reference: `apps/gallery.dart`. Still open: `list`,
  `tabs`, and `grid`/`row`/`column` layout helpers.
- **M4 — liveness polish.** Re-run on Accept and on resize, error banner,
  `canvas` widget over the Pixmap path, Apps menu.
- **M5 — standalone.** `dartui --app Calc`: the same class from the same image,
  its own process, no workspace chrome. The reason §2 exists.

## 11. Decisions locked, and what is still open

**Locked:** user code runs in the language isolate; no `dart:cocoa` in user
apps; **one app at a time, on one surface, moved rather than duplicated**; the
surface named in the envelope but not in every command; absolute frames on the
wire with layout as a language-side library; top-left coordinates; events as
`ask()` requests; curated widget vocabulary; construction via the
workspace-variable path rather than mirrors; `build(ui)` duck-typed, no base
class to inherit.

**Open:** whether the widget set ever gets an escape hatch to raw selectors
(and if so, how it fails safe); whether one app may later own a second window
(an inspector, a palette) — the envelope leaves the door open; what M5's
standalone process does about the Transcript and the debugger.
