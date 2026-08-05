# SOUND_EDITOR_PLAN — an ADSR instrument panel for the synth

The sprite editor's sibling: **Games ▸ Sound Editor**, a utility window that
edits the synth's full `Effect` recipe — the parameter space the eleven
presets are hand-tuned points in — auditions it through the real synth, and
saves it as source in the image.

## What recon established

1. **The synth is already an ADSR instrument** (`gp_synth.h`): an `Effect` =
   duration + up to 4 `Oscillator`s (sine/square/saw/triangle/noise/pulse ×
   freq/amp/phase/pulse-width) + `Adsr` (attack/decay/release seconds,
   sustain level) + linear sweep (start/end Hz) + noise mix + tanh
   distortion + echo (count/delay/decay). `render(e, rng)` → PCM;
   deterministic given the LCG seed. The presets
   (`preset_coin` = two sines 987.77/1318.51 + env .01/.1/.3/.15, …) are
   just Effects — transcribable as the editor's starting points.
2. **The wire ships only preset names** (`gpsound` slot + name + 2 doubles →
   the preset chain → `eng->sfx()->define(slot, snd)`); the Effect struct
   never crosses. One new op closes the gap.
3. **Slots**: 0..63 (`kMaxSfxSlots`); ST presets park at the top
   (64-11..63), Dart games use low slots. The editor auditions on slot 0 —
   safe because the editor owns the pane (sprite-editor mutual exclusion),
   so no game's slots are live.
4. **Audio needs the engine open** (`gpApply` refuses when closed) → the
   editor acquires the pane exactly as the sprite editor does — and uses it:
   the envelope/sweep visualization is DRAWN ON THE METAL PANE with gpline/
   gptext ops. The editor renders its UI with the same engine that plays
   its sounds.

## The one native addition

`['gpeffect', slot, duration, a, d, s, r, sweepStart, sweepEnd, noiseMix,
distortion, echoCount, echoDelay, echoDecay, seed, oscCount,
(wave, freq, amp, phase, pulseWidth) × oscCount]`

→ build `Effect`, `Lcg rng(seed)` (seed crosses the wire so noisy recipes
reproduce exactly), `render`, `eng->sfx()->define(slot, snd)`. ~40 lines in
gp_natives.mm beside gpsound; all machinery below exists.

**The flat parameter order is THE contract** — one canonical order shared by
the native parser, the Dart model (`paramsList()`), the ST face, and saved
sheets. It is written down once, here, and every consumer cites it.

## The pieces (sprite-editor pattern throughout)

- **dart:cocoa**: `stGpEffect(cls, slot, params)` → ships the op;
  `stGpPlaySlot(cls, slot)` → `['gpplay', slot]`.
- **Overlay 80**: `Sound class >> effect: params slot: n` +
  `Sound class >> playSlot: n` (`<stprim:>`).
- **Saved form** — a sound sheet class (store path, hall-of-fame doctrine):

  ```smalltalk
  "SoundFx: Laser — WRITTEN BY THE SOUND EDITOR ..."
  Object subclass: Laser [
      Laser class >> isSoundSheet [ ^true ]
      Laser class >> params [ ^#(0.3 0.01 0.1 0.3 0.15 ...) ]
      Laser class >> playOn: slot [
          Sound effect: self params slot: slot. Sound playSlot: slot ]
      Laser class >> play [ ^self playOn: 0 ]
  ]
  ```

- **Model** `cocoa/workspace/sounded_model.dart` (pure, headless-tested):
  fields + clamps, osc add/remove, `paramsList()`/`fromParams()` round-trip,
  `sheetSource()`, `codeSnippet()`, the 11 transcribed preset seeds,
  `randomize(rng)`/`mutate(rng)` (the sfxr joy — bounded musical ranges).
- **Window** (~980×560, fixed): left = the Metal pane (512×256) drawing
  envelope + sweep + osc stack; below it the 4 oscillator rows (wave popup,
  freq/amp/phase/pw). Right = labelled sliders (duration, A, D, S, R, sweep
  ×2, noise, distortion, echo ×3) + seed field + preset popup + Play +
  Randomize/Mutate + New/Save/Load/Copy Code + status.
- **Language isolate**: `sndstore` (the same `_hostStoreClass`), `sndlist`
  (greps `isSoundSheet`), `sndload` (name + params via stInvokeStatic).
- **Verbs**: `sounded [Name]`, `soundedclose`, `sndnew`, `sndstat`,
  `sndparams` (the flat list — smoke asserts it exactly), `sndset <field>
  <v>`, `sndosc <i> <prop> <v>`, `sndpreset <name>`, `sndplay`,
  `sndsave [Name]`, `sndload <Name>`, `sndlist`.
- **Tests**: model test in the battery (tier2b); a `gpeffect` case in the
  headless synth tier (define a custom effect, assert no error + nonzero
  samples via the existing sfx harness if it exposes that — else wire-level:
  gpApply answers null); gui_smoke: open → set attack → `sndparams` exact →
  play ok → save → listed → `SmokeSound play` via doit → mutate → load
  reverts → close.
- **Docs**: GAME_LIBRARY.md section + README line.

## Order of work

1. Native `gpeffect` + rebuild all three builds; headless wire proof.
2. Model + battery test.
3. dart:cocoa helpers + overlay 80 methods + gamepane_wire additions.
4. Window + verbs.
5. Smoke + docs + commit/push (pull --rebase first).

## Risks / notes

- Transcribed preset seeds are STARTING POINTS, not the presets themselves
  (some presets randomize internally per render — zap/shoot/hurt draw from
  the rng); the editor's seed field makes its own renders reproducible.
- Echo/duration can push past `kMaxSamples` (10s) — clamp duration ≤ 4s and
  echo tail ≤ the remainder in the MODEL, so the native never truncates.
- No waveform-sample readback exists; the pane draws the ENVELOPE (model
  math), the AUDIO is the native truth via Play. Honest split, documented.
