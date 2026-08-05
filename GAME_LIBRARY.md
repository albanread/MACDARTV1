# The game library

Smalltalk games that play on the Metal pane, inside the running IDE.

[`GAMEPANE_PLAN.md`](GAMEPANE_PLAN.md) is the engine's design — the Metal
layer, the indexed pane, the blitter, the synth. This is the layer above it:
what a *game* is in this system, the library of them that ships, how to write
another, and how to drive one from a script.

The short version: a game is an ordinary image class that registers a
per-frame block with a `GamePane` and answers `launch`. Nothing about it is
special-cased. It is browsable, editable and persistent like every other class,
it plays while you edit it, and you can stop its frame loop between any two
frames and read it.

## The frame-loop contract

Every game in the library, without exception, looks like this:

```smalltalk
MyGame class >> launch [ ^self new start ]

start [
    pane := GamePane new.
    "…one-time setup: palette, sprites, shader, sounds…"
    Galaxigans register: self.
    pane onStep: [ self step ]; run
]

step [
    "…move things, draw things…"
    pane present            "REQUIRED — ends the frame"
]
```

`run` does not loop. It flips a flag and returns immediately: the loop is owned
by the **UI timer**, which invites one frame roughly every 30 ms (`kPullPeriodMs`,
~33fps) and calls `GamePane class >> stepWithKeys:` — the single entry to a
frame, used by the timer, the stepper and every headless test alike. That is
why a game never blocks the IDE, and why the debugger and the Browser stay
usable while one plays.

Read input inside the step with `pane keyHeld: GamePane keyLeft` — a bitmask
sampled once per frame, no event queue to drain. The bits are
`keyLeft 0, keyRight 1, keyUp 2, keyDown 3, keyA 4, keyB 5` (arrows, plus
space/Z for A and X for B).

Register `onReset: [ … ]` if your game holds native or worker state beyond the
step block; it runs the moment the session ends, however it ends — Escape, the
close button, a relaunch, or a force-close.

### Where the blocks live, and why it matters

`onStep:` and `onReset:` keep their blocks **on the Dart side**
(`dart:cocoa`'s `_stGpStep` / `_stGpTeardown`, wired in
`st/world/80_gamepane_wiring.mst`), not in `GamePane`'s class variables where
the corpus put them.

This is not tidiness, it is the difference between a game that survives editing
and one that does not. **An accept reloads the whole ST world**: every class is
rebuilt and its class-side state comes back nil. A running game that loses its
step block that way is not paused or slowed — it is *over*. The timer keeps
inviting frames, every one finds nothing to run, and the game freezes on
whatever it was showing, alive and responsive and permanently still. It cannot
even repair itself: a running method's globals are already bound to the
pre-reload class, so it would write a variable nobody reads.

Two real bugs came from exactly this. Galaxigans persists its high scores *by
accepting a class*, so finishing a qualifying game froze the hall of fame
forever; and accepting any class in the Browser froze whatever was playing.
Dart-side state cannot be reached by a reload, so both are gone at the root.
`st/test/galaxigans_reload_wire.dart` holds that line: it installs a host, plays
a qualifying game, and asserts the loop still runs after a *full* world reload.

## What ships

Six live games and effects, plus a one-shot graphics tier.

| Game | Class | Lives in | Notes |
|---|---|---|---|
| Breakout | `Breakout` | `st/world/44_breakout.mst` | brick-breaking with sound; the worked example |
| Worms | `Worms` | `st/world/48a_worms.mst` | three growing worms, you drive one |
| Galaxigans | `Galaxigans` | `cocoa/workspace/demos/galaxigans.mst` | Galaxian-style shooter ported from x64 assembler; 640×360, sprites, shader sky, ABC music, a persistent hall of fame |
| MandelZoom | `MandelZoom` | `st/world/45_mandelzoom.mst` | unending seahorse-valley dive; **direct** mode |
| MandelVM | `MandelVM` | `st/world/46_mandelvm.mst` | one dive, then stops; **direct** mode |
| FFT | `FftScope` | `st/world/61b_fftscope.mst` | live 60fps spectrum analyzer, steer a tone with ←/→ |

The **Games** menu lists them; **Demos** keeps the one-shot visual tier
(`Waves`, `Mandelbrot`, `Benchmarks` — each answers a single frame, so a demo
never ties up the language isolate).

*Direct* mode (`'direct': true`) opens the raw GPU-backed framebuffer instead of
the retained indexed pane, for games that generate a whole frame on the CPU. It
exists because `blit:` (primitive 215) is a documented no-op stub on this VM —
those games render solid black through the indexed path. `directPal:` /
`directBlit:` in `st/world/83_gamepane_direct.mst` are the way in.

## Drawing, sound, music

The corpus speaks MACVM's numbered primitives (`<primitive: 200..215>`), which
this VM never had. `st/world/80_gamepane_wiring.mst` re-points every one of
those selectors — same names, same arity, corpus untouched — at `dart:cocoa`'s
`stGp*` helpers, which append `gp*` wire ops to a per-isolate command buffer.
The driver drains it once per tick and ships one `['draw', ops]` to the UI, so
an ST game rides exactly the same pane, pacing, keystate and teardown machinery
as a Dart one.

- **Pixels** — `cls:`, `point:y:color:`, `line:y:to:y:color:`,
  `fill:y:width:height:color:`, `disc:y:radius:color:`, `paletteAt:r:g:b:`,
  `linePaletteAt:…` (per-scanline palettes), `clearR:g:b:`, `present`
- **Sprites** — `defineSprite:` from `'/'`-separated hex-row art (4 bits/pixel),
  then `colorAt:r:g:b:` and `moveTo:y:` on the handle; multi-frame via
  `addFrame:` / `place:`
- **Text** — `text:x:y:r:g:b:scale:` over a real 5×7 ASCII atlas, and
  `textClear`. The overlay is *retained* between frames, so a changing score
  wants `textClear` first or the digits pile up into solid blocks. (MACVM's own
  pane had no text at all — this is new here.)
- **Shader** — `shader:` compiles MSL for the bottom layer, `shaderParam:value:`
  animates it
- **Sound** — `Sound coin/jump/zap/shoot/explode/powerup/hurt/click/bang/blip`
  (and `Sound preset:`), played with `play`
- **Music** — `Tune fromAbc:` compiles ABC notation to flat MIDI events

Headless, with no driver draining it, the buffer simply fills and is never
shipped — which preserves the corpus's documented "silently a no-op" contract
*and* makes every one of these assertable without a window
(`st/test/gamepane_wire.dart`, 38 checks).

## Adding a game

Two routes, and the difference is only where the file lives.

**In the world** — add `NN_yourgame.mst` under `st/world/`, then a row in
`_kStGames` (`language.dart`) giving its name, class, `launch` selector and a
blurb. It boots with the image and appears in the Games menu.

**From `demos/`** — drop a `.mst` in `cocoa/workspace/demos/` and hit Rescan.
It installs into the running image and plays through the same pull loop; no
registry row needed, because an unregistered name falls back to the class of
that name and sends it `launch`. Galaxigans works this way. This is the better
route while writing one: the menu *is* the folder.

Either way:

- answer `launch` on the class side (`^self new start`)
- declare `paneWidth` / `paneHeight` on the class side if you want a resolution
  other than the default 320×240 — that keeps the size with the game rather
  than in a table its author cannot see (Galaxigans asks for its original's
  640×360)
- end every frame with `present`
- keep per-session state reachable from the step block, and register an
  `onReset:` if it is native or spawned

## Driving one from a script

Every verb below goes through the control plane
(`python3 macdart/tcl/stgui_ctl.py <verb>`), so games are scriptable and
testable without a human at the keyboard.

```bash
python3 macdart/tcl/stgui_ctl.py stgame Breakout
```

| Verb | Does |
|---|---|
| `stgame <name>` | launch a registered game (`demorun <name>` for one in `demos/`) |
| `demostop` / `stgamestop` | end the session |
| `gppause` | park the loop between frames |
| `gpstep [n]` | take n frames **now**, and say where that left the game |
| `gprun` | hand the loop back to the timer |
| `gpwhere` | parked/running, frame number, ops the last frame drew, key source |
| `gpkeys <mask\|->` | what the next frames see instead of the keyboard |
| `gpsnap <file.png>` | the pane's actual pixels (a window grab cannot see a `CAMetalLayer`) |
| `gpstat` | engine counters |
| `doit st> …` | read *or poke* the running game |

### The frame stepper

A game is not a call stack, it is a loop of discrete frames — so the debugger it
wants is a gate on the loop, not breakpoints. Since a whole frame is one
`stepWithKeys:` call, gating the invitation is the entire mechanism. Nothing is
suspended while parked, so the ordinary `doit` is the introspection surface.

Frame start and frame end are the same instant here: nothing runs between the
last statement of frame N and the first of N+1. So one park point serves both
readings — look at what a frame *did* with `gpwhere` / `doit` / `gpsnap`, and set
up what the next one *sees* with `gpkeys` / `doit`.

Stepping runs the frames immediately rather than waiting for the timer to
deliver them, so stepping a thousand frames to reach the next attract flip is
instant instead of thirty seconds.

```bash
python3 macdart/tcl/stgui_ctl.py gpkeys 16
```

That holds fire; one `gpstep` then shows `#attract` become `#playing`, with the
draw-op count jumping from 62 to 463 as the wave forms.

One trap worth knowing if you touch the driver: the UI schedules the next tick
from *inside* the paint it does for the current one, so a tick that goes
unanswered ends the pull loop for good. A parked loop therefore still answers
every invitation, with an empty batch — no ops applied, and the native
`begin_frame` opens a command buffer rather than clearing, so the pane holds the
frame you stopped on.

## The sprite editor

**Games ▸ Sprite Editor** opens a real utility window — Cocoa controls around
the actual Metal pane — for drawing the sprites everything above renders:
pixels on a checkerboard grid (click paints, drag strokes), the 16-entry
per-sprite palette (swatches + RGB sliders; entry 0 is transparent and wears a
diagonal to say so), animation frames (add/dup/del, played by the engine
itself at a chosen fps), and a live preview showing the art at 1x/2x/4x —
rendered by the same engine a game uses, because the preview area literally
hosts the engine's view. Design notes in
[`SPRITE_EDITOR_PLAN.md`](SPRITE_EDITOR_PLAN.md).

**A saved sheet is source in the image** (the hall-of-fame doctrine): Save
writes an ordinary class through the store path — parse-checked, persistent,
Browser-editable, and no world reload, so nothing running is disturbed. The
whole consumption API is one send:

```smalltalk
ship := ShipSprites installOn: pane.   "art + frames + palette, ready to move"
ship moveTo: 100 y: 80.
```

Copy Code exports the raw `defineSprite:`/`addFrame:`/`colorAt:` calls instead,
for art pasted straight into a game. The editor and a running game share the
one engine: launching a game borrows the pane away from the preview, and the
editor's Preview button takes it back.

Scripted face (same handlers the mouse drives): `sprited` / `spritedclose`,
`spednew`, `spedtool pencil|fill|pick`, `spedcolor <0-15>`, `spedrgb r g b`,
`spedpaint x y`, `spedframe add|dup|del|next|prev`, `spedrows` (the current
frame as exact hex rows), `spedname`, `spedsave [Name]`, `spedload <Name>`,
`spedlist`, `spedstat`. The document model is pure Dart
(`cocoa/workspace/spriteed_model.dart`), tested headless in the battery.

## Testing

| Tier | What it proves |
|---|---|
| `st/test/spriteed_model_test.dart` | the sprite editor's document — pixels/frames/palette ops, hex-row round-trip, sheet-class source — pure Dart, no world |
| `st/test/gamepane_wire.dart` | the exact `gp*` ops a game ships, headless — overlay, helpers, sound map, ABC compiler and step loop all agree, before any pixel exists |
| `st/test/galaxigans_smoke.mst` | a real game played through: dive, fire, collisions, waves, the dance, the hall of fame, the attract timeout |
| `st/test/galaxigans_reload_wire.dart` | the save path does not kill the frame loop, and a full world reload no longer can either |
| `st/test/gui_smoke.sh` | live in the GUI: frames tick, `gpsnap` writes real pixels, a step advances exactly one frame, a park does not drift, `gprun` resumes |

`./macdart/st/test/run_all.sh` runs the lot; add `--gui` for the last row.

## House rules

- **The corpus stays verbatim.** MACVM's `.mst` files are not edited. Wiring
  goes in `dart:cocoa` helpers and late-loading world overlays (80, 83), which
  reopen the same selectors and win by load order. That is why 43's own comments
  still read true even though nothing in it runs its primitives any more.
- **`present` ends a frame.** A step that forgets it draws into a buffer nobody
  ships.
- **State that must outlive a reload belongs on the Dart side.** The frame
  blocks are there for that reason; class-side state in ST is fair game for any
  accept.
