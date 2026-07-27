# The Game Pane — MacGamePane, converted to C++, in the VM

How a proper 2D retro game — palette-indexed layers, GPU sprites, per-scanline
palette tricks, chiptune SFX — gets written **in Dart** and runs on MACDART,
with its game loop JIT-compiled and its rendering on Metal.

Companion to `WORKSPACE_PLAN.md` (the workspace), `APP_PANE_PLAN.md` (retained
controls), and `COCOA_PLAN.md` (the bridge). Written before the code, so the
constraints are argued once. The engine being converted is
[MacGamePane](~/claudeprojects/MacGamePane) — the Rust engine already built for
exactly this purpose (its README names sibling VMs as the intended consumers),
itself distilled from three earlier implementations, one of which
(`~/claudeprojects/SuperTerminalMetal`) is C++/Objective-C++ and serves as a
lift reference where its code matches. MACVM's own integration design
(`MACVM/docs/gamepane_design.md`) is the third input: its adversarially-reviewed
threading model is what §3 adapts — and mostly *simplifies*, because MACDART's
architecture already contains the machinery MACVM had to invent.

## 0. Scope

**Converted (the engine, Rust → ObjC++/C++):** the layered Metal pane —
shader background, 8-bit indexed framebuffer with per-scanline palettes,
overscan + scroll, 8 buffer slots with a GPU compute blitter, 16-colour
sprites with per-sprite palettes, seven-segment text overlay — plus the SFX
synthesizer and its AVAudioEngine playback. Ported into `macdart/cocoa/` as
part of the `dart_cocoa` static library; no Rust in the build.

**Not converted now (explicit, mirrors the engine's own deferrals):** ABC-tune
playback (parser + AVMIDIPlayer; deferred unless the audio report shows it
trivial), gamepad input, SID emulation, the VoiceScript sequencer, live pane
resize. Each is a follow-up, not a silent omission.

## 1. What already exists in MACDART, and what that decides

The whole reason MACVM's design needed three named threads, a scene shadow,
and a single-outstanding `GameStep` discipline is that its VM worker is a
serial channel-fed thread that must never be re-entered. MACDART's shape is
different in three load-bearing ways:

1. **The UI isolate already runs on thread 0.** AppKit — and therefore Metal —
   is legal exactly where all `dart:cocoa` natives already execute. There is
   no cross-thread Metal question: every engine call is a native invoked by
   the UI isolate, single-owner by construction. (MACVM had to *choose* a
   main-thread frame driver to make this true; here it is true before we
   start.)
2. **The pull protocol is the frame driver.** Built and proven this week for
   demos: the UI invites exactly one frame at a time (`['port', ctl]` →
   tick → one reply), the pacing law guarantees run-loop idle after every
   paint, and a slow game degrades to fewer fps instead of freezing — the
   exact backpressure MACVM's single-outstanding `GameStep` exists to provide.
   The game pane rides it unchanged.
3. **The gamestate key poller is the input layer.** Ticks already carry
   `[downKeycodes, modifierFlags]`; capture (swallow non-Cmd keys) already
   follows "demo running AND Demos tab frontmost". MacGamePane's
   `MacGamePaneKeyView`/`HELD_KEYS` first-responder machinery is therefore
   **not ported at all** — the one piece of the engine MACDART replaces
   outright rather than converts.

And one law carries over verbatim from the App pane: **game code never
imports `dart:cocoa`.** The game runs in its own isolate (spawned from the
Demos menu like every demo — killable by Stop, crash costs the isolate never
the window) and *describes* a retained scene; the UI isolate owns the native
engine objects and applies the description. Pixels never cross the port —
after the one-time asset upload, a frame's traffic is sprite transforms,
scroll offsets, and palette pokes: a few hundred bytes.

## 2. The retained-scene wire

A game is a pull demo whose draw list uses new verbs. Same envelope
(`['draw', cmds]`), same pacer, same Stop, same menu discovery — the game
pane verbs simply join `clear/rect/oval/line/text/blit` in the command
vocabulary, and the first one (`gpopen`) swaps the Demos tab's NSImageView
for the Metal pane view:

```
one-time (load phase):
  ['gpopen', w, h]                 create panes at a fixed logical size; show the Metal view
  ['gppal', i, r, g, b]            global palette entry (16-255)
  ['gplinepal', line, i, r, g, b]  per-scanline palette entry (1-15)
  ['gpsprite', id, 'f0f/0f0/f0f']  define sprite art (hex rows, width derived)
  ['gpframe', id, 'rows']          add an animation frame
  ['gpspritepal', id, i, r, g, b]  the sprite's own 16-colour palette
  ['gpsound', id, preset|params]   define an SFX slot
  ['gpshader', mslBody]            the fullscreen background shader (M4)

per frame (mutate the retained scene):
  ['gpplace', id, x, y, frame, scale, rot, alpha]
  ['gpscroll', x, y]
  ['gppset', x, y, i] / ['gpline', ...] / ['gpfill', ...] / ['gpcircle'|'gpdisc', ...]
  ['gpload', slot, base64]         bulk indexed-buffer load (the MandelZoom path)
  ['gpblit', src, dst, mode, ...]  slot-to-slot GPU blit (copy/key/and/or/xor/clear)
  ['gpswap']                       front/back buffer swap
  ['gpplay', id]                   trigger a sound
  ['gptext', x, y, s, r, g, b]     HUD overlay
```

The UI isolate applies the whole list, renders the four layers in order
(shader → indexed → sprites → text), presents, and — pull — invites the next
frame with the current key state. Handles (`id`) are small integers minted by
the game; the UI keeps plain arrays. No generation tags in v1: exactly one
game runs at a time, `stopDemo` tears the registry down with the pane, and
the captured-port identity check already orphans stale ticks.

**There is deliberately no `present` verb.** MACVM's sink streams commands
one at a time, so a present could land mid-frame — their worst rendering bug
(a black flash every frame: a drain presented between a frame's `cls` and its
last draw; commit `a3ee31a`, and their world file now shouts "every frame
must end with present" at users). Our wire ships the **whole frame as one
list, applied atomically, presented once at the end** — the flicker class
and the user-facing rule both cease to exist.

A bulk path exists from day one because MACVM had to retrofit theirs
(76,800 point commands per frame until commit `db9ff45` added `blit:`):
`['gpload', slot, base64]` bulk-loads an indexed buffer into any slot —
MandelZoom-style demos ship one string per frame, the same way `Pixmap`
blits do today.

Range checks live at the native boundary: the Rust engine `assert!`-panics on
out-of-range palette indices and slots, and in an embedded VM that is an
abort — so every native validates and throws a Dart exception instead
(MACVM's design records the same rule; here `onDemoMsg`'s existing try/catch
turns a bad command into a logged dropped frame, never a dead window).

## 3. Rendering and pacing

- The pane is a `CAMetalLayer`-backed NSView sitting exactly where
  `gDemoView` sits; `gpopen` shows it, `stopDemo`/`gpclose` hides it and
  frees the engine objects. The classic NSImage canvas is untouched — old
  demos and the game pane coexist, one visible at a time.
- Render happens **inline in the draw handler** (the flush law: work from the
  message pump, idle bought after every paint by the pacer). One
  `nextDrawable`/present per applied frame, at the tick cadence (~30 fps;
  `kPullPeriodMs`). No CADisplayLink/CVDisplayLink in v1 — MACVM needed a
  decoupled display-rate re-present because its worker could stall for whole
  doits; our game isolate answers ticks or it doesn't run, and re-presenting
  an unchanged retained scene buys nothing at the cost of a second driver.
- Fixed logical resolution, chosen at `gpopen` (e.g. 424×176 for the demo
  canvas's aspect), letterboxed by the view; live resize deferred exactly as
  MACVM deferred it.

## 4. Verification (the house rule: headless or it doesn't exist)

`cacheDisplayInRect:` snapshots **do not capture a CAMetalLayer's content**
(external-layer pixels aren't in the view hierarchy's backing store), so the
existing `snap` verb would lie about the game pane. The engine therefore
ships with `gpsnap <path>`: a native that blits the last-presented texture
back to CPU memory and writes a PNG — the demo-canvas equivalent of reading
the real glass. The regress suite drives a game headlessly over the control
plane: open, define a sprite, place it, tick, `gpsnap`, assert pixels.

## 5. Conversion strategy (Rust → C++), grounded per subsystem

The Rust engine is small and cleanly layered — the graphics crate is ~1,900
lines of implementation across five modules, the synth ~550 — and every Metal
shader is an **embedded MSL string that transfers to ObjC++ verbatim** (five
render/compute sources, all captured in the survey). So the primary strategy
is **port from the Rust** (it is the distilled, tested statement of the
design); SuperTerminalMetal is consulted per subsystem only where the survey
finds genuinely liftable ObjC++.

Per subsystem, with the facts that will bite a careless port:

- **IndexedPane (565 lines).** 8 world-sized `R8Uint` textures + CPU mirrors
  + dirty flags; palette is ONE flat `float4` buffer of
  `viewportH*16 + 240` entries — per-line region first (16 slots/line,
  slot 0 dead), then 240 globals. The fragment shader keys per-line colours
  off the **screen** scanline, not the world row — per-line palettes are
  raster-locked and do not scroll (the copper behaviour, deliberate).
  `render()` always composites the FRONT slot regardless of the active draw
  slot; `swap_buffers` swaps buffer/texture/dirty *identities*, not contents.
  Uniforms: `{scroll_x, scroll_y, viewport_w, viewport_h}` as 4 floats.
- **Sprites (491 lines).** One `R8Uint` texture **per frame**, uploaded once
  at definition; 16-`float4` (256-byte) palette buffer per definition;
  `x,y` is the world-space **centre** (rotation pivot); per-instance
  quad built CPU-side (TL,TR,BL,BR strip, rotation applied in screen space,
  y-down) and passed via `setVertexBytes` — one draw call per visible
  instance, straight src-alpha blending. `hit()` is AABB, rotation ignored.
  Art rows: `/`-separated hex digits, `.` = transparent, width from row 0,
  ragged rows rejected.
- **Blitter (420 lines).** Four compute kernels (`copy`, `transparent`,
  `minterm` AND/OR/XOR, `clear`), 32-byte `BlitParams`, 16×16 threadgroups,
  one encoder per blit ordered before the render passes. Two Rust behaviours
  the port must **fix, not copy**: no CPU-side bounds clipping (out-of-range
  rects panic there; here they must clip), and the CPU-mirror writeback sets
  `dirty[dst]=false` unconditionally, silently discarding pre-blit CPU draws
  — the port reconciles by uploading a dirty destination before blitting.
- **TextOverlay (284 lines).** Viewport-sized RGBA8 CPU buffer, seven-segment
  digits (`[0x3F,0x06,0x5B,0x4F,0x66,0x6D,0x7D,0x07,0x7F,0x6F]`), letters as
  placeholder boxes, one full-screen sampled pass, alpha-blended, Load.
- **ShaderPane (160 lines).** Runtime `newLibraryWithSource:` of a fixed
  header (`Uniforms{time, aspect, p[8]}` + big-triangle vertex fn) + the
  game's `fmain` body. Compile errors must surface as a logged Dart error,
  never an abort.
- **Frame shape.** Four separate render passes into the same drawable
  texture per frame — shader (Clear, hardcoded black) → indexed (Load) →
  sprites (Load) → text (Load) — then `presentDrawable`/`commit`, no
  wait-until-completed. All pipelines target `BGRA8Unorm`, matching the
  CAMetalLayer default. A nil `nextDrawable` skips the frame, not an error.
- **Input.** The engine's `MacGamePaneKeyView`/`HELD_KEYS` (first-responder
  NSView subclass + 128 atomics) is confirmed to be exactly what our key
  poller already does with an event monitor — **not ported**, as §1 decided.
- **Synth (554 lines, pure C++, no GPU/ObjC).** Port the formulas literally:
  the non-standard saw (`floor(n+0.5)` form), the linear-frequency sweep
  evaluated as `sin(2πf(t)·t)` (not a phase-integrated chirp), the in-place
  echo whose taps deliberately re-read earlier taps' output, normalize that
  only attenuates (`peak > 1.0`), the LCG (`x·1103515245+12345`, u32, high
  bits via `/65536 %32768`), 44.1kHz stereo f64 interleaved, 10s cap. The
  11 presets' exact parameters are recorded in the survey and port verbatim
  (`coin` = 987.77 + 1318.51 Hz sines, etc.). Unit-testable headlessly.
- **Playback (ObjC++).** `AVAudioEngine` + `AVAudioPlayerNode` +
  `initStandardFormatWithSampleRate:44100 channels:2` (float32
  deinterleaved — the synth's f64 interleaved converts at define time);
  order is load-bearing: alloc engine → alloc player → `attachNode:` →
  format → `connect:to:format:` → `startAndReturnError:` → `[player play]`.
  64 fixed slots, define replaces (releasing the old buffer), `play` =
  `scheduleBuffer:completionHandler:nil` — overlapping SFX just sum. ONE
  engine per process, created lazily (two concurrent starts abort
  uncatchably — documented, designed around). Port fixes two known Rust
  leaks: release the format object, stop engine/player before release.
- **ABC tunes: deferred, cheaply.** The parser is 1,130 lines — 36% of the
  audio crate — behind a 3-item boundary (`MidiEvent`, `Tune`,
  `parse_tune`), consumed only via a temp `.mid` + `AVMIDIPlayer`. M4 can
  ship tune playback with a hand-built event list and no parser at all;
  the parser ports later if wanted.

## 5b. MACVM's scars, inherited as immunities

MACVM built this integration first (`world/43_gamepane.mst` + two GUIs), and
its commit history records exactly where it bled. Each scar maps to a
structural answer here — designed in, not left to be rediscovered:

| MACVM's bug (commit) | Their fix | Why MACDART can't reproduce it |
|---|---|---|
| Mid-frame present → per-frame black flash (`a3ee31a`) | Present stands down while the game loop runs; users must end frames with `present` | Whole frame is one atomically-applied list; present is implicit at its end; no user rule |
| Stale held keys poison the *next* game — Esc's `keyUp:` lands nowhere after close (`30a3716` #1, fixed twice in two GUIs) | Manual `clear_all()` at open in each GUI | `keyCapture` toggles clear the board natively, and toggles are wired to run/stop/tab-switch already |
| Leaked `NSWindow`+`CAMetalLayer` per session (`30a3716` #2) | Release on close | No window: one embedded view created once and reused, like `gDemoImage` |
| Worker isolates never terminated; 5th launch hit the cap (`30a3716` #3 — why their `onReset:` exists) | An `onReset:` teardown hook per game | Stop kills the game isolate; games that spawn workers follow the mandelbrot idle-retire pattern (`04_mandelbrot.dart`) |
| No teardown on VM restart — orphaned window+timer (`30a3716` #4) | A restart hook, later | `stopDemo` is the one teardown path and already runs on every stop/replace |
| `StepBlock` GC-rooted dead games across sessions (`518a2ca`) | Call `reset` on close | The game *is* the isolate; kill frees everything it rooted |
| Nested VM entry corrupts interp state → step must be "top-level only" (`cocoa_gui/game.rs`) | A supervisor pull loop | Isolate message handling is top-level by construction |

Two of their empirical findings also transfer as *validation*: their games
(Breakout, Worms, MandelZoom) drive almost everything through the indexed
pane + bulk blit — sprites shipped but went unused — confirming M1 alone
already enables a real game class; and their input model (six abstract keys
in a mask) proved sufficient, so our richer raw-keycode gamestate is safely
a superset. Their ≥1-frame input→pixel latency consequence applies to us
identically (tick → game isolate → draw → paint) and is accepted for the
same reason.

## 5c. SuperTerminalMetal: quarry, not foundation

The C++ ancestor was surveyed (~117k lines, 217 files) for direct lifts. The
verdict: **port from the Rust; quarry SuperTerminalMetal selectively.** Its
renderer is a 7,300-line god object that calls a 10-subsystem singleton from
inside the render loop and `#include`s a `.mm` into a `.mm`; its shallow git
history marks it a code dump, not a maintained library. It also carries two
live bugs the Rust engine already fixed by design — `replaceRegion:` on
Private-storage textures (illegal under Metal validation; the Rust uses
Shared, keep that), and a LORES blit whose host bindings don't match its
kernel signature. MacGamePane *is* the distilled, tested statement of this
engine; that is what converts.

Worth quarrying later, recorded so it isn't re-discovered: the
`AVAudioSourceNode` render-callback glue (`AudioManager.mm:1483-1560`, ~75
lines — the pattern for *realtime* voices if `VoiceBank` ever goes live;
preallocate the callback buffer, theirs mallocs on the audio thread), the
copper-bar/gradient `PaletteAutomation` structs, the prebuilt Unscii font
atlases (a real font for the text overlay someday), and `CAMetalLayer`
config details (`framebufferOnly`, `maximumDrawableCount=3`,
backing-scale handling in `viewDidChangeBackingProperties`).

## 6. Integration seams

- **Sources:** `macdart/cocoa/gamepane/` — `gamepane_engine.h/.mm` (the
  layered engine: device, queue, panes, registry), `gamepane_synth.h/.cc`
  (pure-C++ synth, unit-testable without a GPU), `gamepane_natives.mm` (the
  Dart boundary: validation + verb dispatch). Compiled MRC like the rest of
  the bridge; registered in `cocoa_natives.mm`'s `COCOA_NATIVE_LIST`.
- **CMake:** the files join `dart_cocoa`; frameworks add
  `Metal QuartzCore AVFoundation`. (They link into `dart` too, harmlessly —
  same status quo as AppKit: the natives exist everywhere, work under
  `dartui` where thread 0 is the UI isolate.)
- **workspace.dart:** `renderDemo` grows the `gp*` verb dispatch (a table,
  not an if-chain, at this vocabulary size); `buildDemosTab` hosts the Metal
  view; `stopDemo` tears down; control verbs `gpsnap`/`gpstat` for the suite.
- **Game-side library:** `demos/gamepane.dart` (a library like `pixmap.dart`,
  no `// Demo:` header) — `GamePane`, `Sprite`, `Sound` classes that mint
  handles and serialize verbs, so a game reads like the MACVM Smalltalk
  sketch: `ship.move(dx, 0)`, `coin.play()`, not raw lists.
- **Games are demos:** discovered by the same `// Demo:` header, listed in
  the same menu, stopped by the same button. A first shipped game
  (`12_scroller.dart` or similar) is the M2 capstone.

## 6b. The direct framebuffer path — a raw-speed escape hatch

Retained mode ships tiny per-frame deltas: perfect for sprite games, useless
for **full-frame CPU rendering** (plasma, fire, a raycaster, a live Julia set),
where every pixel changes every frame and there is nothing small to send. For
those, `gpDirect(w, h)` hands the game a framebuffer **in GPU memory it writes
directly** — no command protocol, no upload, no copy.

Why it works: Apple Silicon is unified memory, so a `MTLStorageModeShared`
buffer's `contents()` is CPU-writable memory the GPU samples. Dart 1.24 has no
`dart:ffi`, but `Dart_NewExternalTypedData(kUint8, ptr, len)` wraps that pointer
as a `Uint8List` with no finalizer (the VM never frees it — thread 0 owns it).
The game writes palette indices into the list; the bytes ARE in GPU memory. A
linear `R8Uint` texture view over the buffer
(`newTextureWithDescriptor:offset:bytesPerRow:`) is sampled by a 256-colour
palette shader, so index→colour and palette-cycling come along for free.

The three asterisks from the design discussion, resolved:

- **The handle is per-isolate.** External typed data cannot cross a SendPort and
  stay backed by the same memory, so each writer obtains its own view via the
  `gpBackbuffer()` native — every view aliases the one buffer. That is the
  feature, not the limit: several worker isolates can compute disjoint bands
  straight into one GPU buffer, no copy between them.
- **Present stays on thread 0.** Writes are off-thread; the pull tick still
  carries the present to the UI isolate, which renders and flips. It composes
  with the pacer unchanged.
- **We now own the sync.** THREE rotating buffers: the game writes buffer W
  while the GPU reads the one presented last; present renders W, then advances
  the write index (an atomic). Three-deep plus pull pacing means the buffer the
  game writes is always ≥2 frames past its last GPU read — no fence needed (a
  completion-handler fence is the belt-and-braces upgrade).

Lifetime is the single footgun, designed out: the buffers are freed only in
`gpClose`, and `stopDemo` kills the game isolate *first*, so no live `Uint8List`
ever views freed memory. The safety upside is real — external typed data is
length-bounded by the VM, so a game physically cannot scribble past its
framebuffer (a raw pointer would).

Wire: `['gpopen', w, h, w, h, 1]` (mode 1 = direct) swaps the Metal view as
usual; `['gpdpal', i, r, g, b]` sets a palette entry (0–255); each frame the
game calls `gpBackbuffer()`, fills it, and sends its pull frame (a HUD `gptext`,
or an empty list) to present. `gpstat` reports the row STRIDE (bytesPerRow,
rounded to Metal's linear-texture alignment) so the game addresses
`fb[y*stride + x]`. It coexists with retained mode — one engine, two front ends.

## 7. Milestones

- **M0 — pane + proof of pixels.** CMake wiring; CAMetalLayer view embedded
  and swappable in the Demos tab; clear-to-colour frame; `gpsnap` readback.
  Retires the "Metal in dartui at all" risk first, headlessly verifiable.
- **M1 — the indexed pane.** Framebuffer + global/per-scanline palettes +
  overscan/scroll + primitives, palette-LUT render pass from the engine's own
  MSL; a raster-bars demo over pull ticks.
- **M2 — sprites, blitter, a game.** Sprite definition/placement/animation/
  hit, slot blits, `demos/gamepane.dart`, a playable keyed game. The engine
  is now "proper 2D retro games from Dart".
- **M3 — sound.** The synth (presets verbatim) + one AVAudioEngine per
  process (the documented concurrent-start abort is designed around, not
  discovered again); `coin.play()` in the M2 game.
- **M4 — dressing.** Shader background layer, text overlay HUD; ABC tunes
  if and only if the audio survey showed the boundary trivial.
- **M6 — the direct framebuffer (§6b).** `gpDirect`: a shared-buffer indexed
  framebuffer the game writes as external typed data, triple-buffered, sampled
  by a palette shader; `gpBackbuffer()` + `gpdpal` + a stride-aware `gpstat`.
  A live Julia set is the one-screen proof that CPU→GPU is a memory write, not
  a protocol.

Each milestone: builds in `build-release`, drivable from the control plane,
`gpsnap` evidence in the transcript, committed.

## 8. Decisions locked, decisions open

**Locked by this design:** engine converted to ObjC++/C++ inside
`dart_cocoa` (no Rust in the build, no dylib plugin); UI isolate owns all
engine objects on thread 0; game logic in a spawned demo isolate over the
pull protocol; retained scene, pixels never cross the port; key poller is
the input layer (engine's key view not ported); fixed logical resolution;
range-validate at the native boundary, throw not abort; `gpsnap` for honest
headless verification.

**Open (decide before or during implementation):**
- whether games later also run in the **language isolate** (image classes,
  hot-reload-while-playing, breakpoints in `onStep` — the full liveness
  story) once the App-pane channel exists; the wire is deliberately
  driver-agnostic so this adds a driver, not a rewrite;
- whether the M4 shader layer accepts arbitrary MSL from game files (it is
  compiled at runtime; a bad shader must fail as a logged error, never an
  abort);
- ABC tunes in M4 or deferred entirely.
