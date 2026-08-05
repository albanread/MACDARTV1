# SPRITE_EDITOR_PLAN — a paint program for the game library

A real utility window: graphically edit the 16-colour sprites the game pane
renders — pixels, per-sprite palette, animation frames — and save them as
**source in the image**, the same doctrine as Galaxigans' hall of fame. A saved
sheet is an ordinary class any game files in and uses with one line.

## What recon established (all verified in code)

1. **The pane can live in any window.** `Cocoa_gpOpen` *returns the NSView*
   (`gp_natives.mm:114`) and the Dart side parents it — `gpEnter` simply does
   `gDemoView.superview().addSubview(gGpView)` (workspace.dart:3972). The
   editor window calls `gpOpen` itself and adds the view to its own hierarchy.
   No native work.
2. **Reopen is the reset.** `GpEngine::open` starts with `close()` — panes
   freed, device and view reused, sprite-def ids restart at 0
   (gp_engine.mm:1364). Defs and frames are append-only (`gpsprite`/`gpframe`
   reject out-of-sequence ids), so the editor's preview never *edits* engine
   state: it rebuilds the tiny scene — reopen + one `gpApply` batch
   (background, def, frames, palette, spawn, `gpanim`, present). Frames apply
   atomically, so the glass never shows a partial rebuild.
3. **The engine animates by itself.** `gpanim` sets per-instance fps
   (gp_natives.mm:244) — preview animation costs zero timers.
4. **Index 0 is transparent** ("palette: index 0 transparent (discard)",
   gp_engine.h:36; `.` in row art is an alias). The editor draws it as
   checkerboard.
5. **Mouse painting needs no native work.** The App-pane canvas is an
   NSImageView + `NSClickGestureRecognizer` wired through the generic
   `onAction` proxy with `locationInView` (workspace.dart:5093). An
   `NSPanGestureRecognizer` wired identically gives drag-paint; the two
   coexist (click = dot, pan = stroke).
6. **The drawing surface is `renderInto`** — clear/rect/oval/line/text/blit
   ops into an NSImage. Grid, checkerboard and swatches are all rects.
7. **ST consumption API** (43 + overlay 80): `pane defineSprite: rows` →
   Sprite; `addFrame:`, `colorAt:r:g:b:`, `moveTo:x y:` / `moveTo:y:frame:`.
   A saved sheet emits `installOn: pane` doing exactly those sends.
8. **Save must STORE, not accept** (live-reload contracts): a program writing
   data uses the host's `storeClass` path — parse-check, image write, one
   class made live, **no world reload** — so saving never disturbs anything
   running (and the editor itself is Dart, immune anyway).

## Decisions

- **Where the code runs:** the UI isolate. Painting is pointer-latency work on
  Cocoa views; the model is small. The language isolate is only touched to
  save/load/list sheets (it owns the image).
- **Files:** `cocoa/workspace/spriteed_model.dart` — the document model, pure
  Dart, no `dart:cocoa`, imported by workspace.dart *and* by a headless test
  (sibling imports are house precedent: demos import `gamepane.dart`). The
  window/controls section lives in workspace.dart like every other feature.
- **Document = sheet class.** Saved source shape:

  ```smalltalk
  "SpriteSheet: Ship — WRITTEN BY THE SPRITE EDITOR ..."
  Object subclass: Ship [
      Ship class >> isSpriteSheet [ ^true ]
      Ship class >> frames [ ^#('0ff0/f11f/...' '...') ]
      Ship class >> palette [ ^#( #(0 0 0) #(230 240 255) ... ) ]  "16 rows"
      Ship class >> installOn: aPane [
          | s | s := aPane defineSprite: self frames first.
          "addFrame: the rest, colorAt: the 15 visible entries"  ^s ]
  ]
  ```

  `installOn:` is the point of the format: a game does
  `ship := Ship installOn: pane.` and has the art, frames and palette in one
  send. `isSpriteSheet` is the discovery marker for listing.
- **Mutual exclusion with games:** the engine is a singleton. Opening the
  editor stops any running demo (`stopDemo`). If a game is launched while the
  editor is up, `gpEnter` re-parents the shared view away — the editor notices
  (ownership flag cleared by a one-line hook in `gpEnter`), suspends preview,
  and its status line says who has the pane; the Preview button takes it back.
- **Window close = hide.** No bridge support for close notifications, and
  `quitOnClose` is quit semantics. `setReleasedWhenClosed(false)`; the red
  button hides the window, the menu item / `sprited` verb shows it again.
  State survives hiding.

## Layout (~980×560, fixed)

```
+------------------------------------------------------------------+
| [grid canvas 432×432]                | Name [______] W [_] H [_]  |
|   checkerboard = transparent        | [Resize]                   |
|   cell size auto from sprite size   | palette: 16 swatches (2×8) |
|                                     | R ▓▓▓▓▓ G ▓▓▓▓ B ▓▓▓▓ #hex |
|                                     | Frame 2/5 [|<][<][>][Add]  |
|                                     |           [Dup][Del]       |
| tools: (Pencil)(Fill)(Pick)         | anim fps [slider] [x] Play |
| [◀][▶][▲][▼] shift   [Clear]        | preview: [Metal pane 424×  |
|                                     |          240 — 1x 2x 4x]   |
| status: …                           | [Save][Load ▾][Copy Code]  |
+------------------------------------------------------------------+
```

## Milestones

- **M1 — model, headless-tested.** `SpriteDoc`: pixels (0..15), frames,
  palette (16×RGB, DB16 default), setPx/fill/shift(wrap)/resize(pad-crop),
  frame add/dup/del, hex-rows emit+parse (`.`≡0 on parse), sheet-source emit,
  `defineSprite:` snippet emit, name validation. Test
  `st/test/spriteed_model_test.dart` (plain `dart`, no `--with-st`);
  run_all.sh tier entry.
- **M2 — the window.** Menu item (Games menu), window + grid canvas with
  click & pan painting, palette swatches canvas, RGB sliders, frame controls,
  tool buttons, status line. All edits repaint via `renderInto`.
- **M3 — the pane preview.** `gpOpen` into the preview box; rebuild = reopen +
  one atomic batch (bg fill, def+frames, `gpspritepal`×15, three `gpspawn` at
  1x/2x/4x via `gpplace` scale, `gpanim` when Play). Coalesced (~10 Hz cap)
  behind a dirty flag; ownership hook in `gpEnter`.
- **M4 — persistence + scripting + docs.** Language-isolate cmds: `spstore`
  (storeClass path), `spload <cls>` → [rows…]+palette, `splist`. UI verbs:
  `sprited [Name]`, `spritedclose`, `spedstat`, `spedpaint x y`, `spedcolor i`,
  `spedrgb`, `spedframe …`, `spedrows`, `spedsave/spedload/spedlist`.
  gui_smoke: open → paint two pixels → `spedrows` exact → save → `spedlist`
  contains → mutate → load → `spedrows` back to saved → close. Docs: section
  in GAME_LIBRARY.md, README line. Battery + smoke green, commit+push.

## Risks / honest notes

- Pan-gesture pixel painting: `locationInView` during pan is the same call the
  click path proves; if a drag event floods, painting is idempotent per cell
  and cheap (one rect repaint). If the recognizer pair misbehaves, fallback is
  click-only painting (still usable) — decision point in M2.
- Preview reopen cost: `open()` recreates layer textures (~424×240) at most
  10×/s while actively painting. If that stutters, drop to rebuild-on-idle
  (200 ms after the last edit). Decision point in M3.
- Undo: out of v1. The model keeps ops small and pure so a single-level undo
  is a later afternoon, not a redesign.
- `installOn:` truth: verified against the exact selectors games already use
  (`defineSprite:`/`addFrame:`/`colorAt:r:g:b:`), and the smoke test files a
  saved sheet into a scratch pane headlessly via the gp wire to prove the
  emitted source actually runs.
